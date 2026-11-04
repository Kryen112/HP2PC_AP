"""The client's end of the file channel shared with the game.

The game's engine has no sockets, so the game and the client talk through a
folder (the channel directory, set in the game's Game.ini by the installer):

- Client to game: ``in.txt`` holds the client's unacknowledged lines, rewritten
  atomically. The game runs it with ``exec`` every quarter second; each line
  calls ``APIn <session> <seq> <+|=><fragment>`` on the mod's console. A line
  longer than one fragment arrives as ``+`` fragments closed by a ``=`` one.
  The game skips sequence numbers it already took and reports the newest with
  ``INACK <session> <seq>``.
- Game to client: the game writes closed batch files
  ``out_<gamesession>_<n>.log`` (UTF-16, newline-separated lines), read here in
  order and deleted. ``ALIVE`` is the game's heartbeat.

A ``PING`` every two seconds keeps the game's side of the link up. The link is
up while the game's batches keep arriving; a new game session means a new game
process, so the old connection ends and a new one begins.

Standalone: no Archipelago imports, so the protocol tests run on a temp folder.
"""
from __future__ import annotations

import asyncio
import logging
import os
import re
import secrets
import time
import unicodedata
from pathlib import Path
from typing import Awaitable, Callable, Optional

INBOUND_FILE = "in.txt"
OUTBOUND_PATTERN = re.compile(r"^out_(\d+)_(\d+)\.log$")

# Characters per inbound fragment. The engine reads each exec line into a fixed
# buffer, so a long line ships in pieces the mod reassembles.
FRAGMENT_CHARS = 200
# Lines per in.txt rewrite. The game runs the whole file each poll, so this caps
# one poll's work; the rest follows once these are acknowledged.
MAX_LINES_PER_FILE = 40
POLL_SECONDS = 0.1
PING_SECONDS = 2.0
# No batch from the game for this long ends the connection. The game's own
# heartbeat is two seconds.
GAME_TIMEOUT_SECONDS = 6.0

logger = logging.getLogger("HP2Client")


# Characters outside latin-1 that have a readable latin-1 spelling but no
# decomposition to one.
_LATIN1_SPELLINGS = {
    "\u0141": "L", "\u0142": "l", "\u0110": "D", "\u0111": "d", "\u0126": "H", "\u0127": "h",
    "\u0131": "i", "\u0152": "OE", "\u0153": "oe", "\u0166": "T", "\u0167": "t",
    "\u2018": "'", "\u2019": "'", "\u201a": "'", "\u201c": '"', "\u201d": '"', "\u201e": '"',
    "\u2013": "-", "\u2014": "-", "\u2026": "...", "\u2022": "*", "\u2122": "TM",
}


def game_text(text: str) -> str:
    """The text as the game can show it: in.txt is latin-1 and so are the
    game's fonts. A character outside latin-1 becomes its spelling without
    accents (L-stroke to L, while latin-1 accents stay), a plain stand-in for
    typographic marks, or '?' when it has no latin spelling at all."""
    if all(ord(character) < 256 for character in text):
        return text
    out = []
    for character in text:
        if ord(character) < 256:
            out.append(character)
        elif character in _LATIN1_SPELLINGS:
            out.append(_LATIN1_SPELLINGS[character])
        else:
            base = "".join(part for part in unicodedata.normalize("NFKD", character)
                           if ord(part) < 256 and not unicodedata.combining(part))
            out.append(base or "?")
    return "".join(out)


def _decode_batch(raw: bytes) -> str:
    if raw[:2] == b"\xfe\xff":
        return raw[2:].decode("utf-16-be", errors="replace")
    if raw[:2] == b"\xff\xfe":
        return raw[2:].decode("utf-16-le", errors="replace")
    if raw[1:2] == b"\x00":
        return raw.decode("utf-16-le", errors="replace")
    return raw.decode("latin-1")


class FileGameLink:
    """One client session on the channel. ``write`` and ``is_closing`` match
    the stream-writer calls the client makes, so the link stands in for one."""

    def __init__(self, channel_dir: Path, session: Optional[str] = None) -> None:
        self.channel_dir = Path(channel_dir)
        self.session = session or secrets.token_hex(4)
        self.game_session: Optional[str] = None
        self.connected = False
        self._next_seq = 1
        self._pending: "list[tuple[int, str, str]]" = []  # (seq, fragment, peer key)
        self._written: Optional[str] = None
        self._last_batch = 0.0
        self._last_ping = 0.0

    # Stream-writer interface used by the client's call sites.
    def write(self, data: bytes) -> None:
        for line in data.decode("utf-8", errors="replace").split("\n"):
            line = line.rstrip("\r")
            if line:
                self.queue_line(line)

    def is_closing(self) -> bool:
        return not self.connected

    def close(self) -> None:
        self.connected = False

    def queue_line(self, line: str) -> None:
        """Queue one logical line as numbered fragments. A newer PEER for the
        same slot replaces an unsent one, since only the latest position matters."""
        line = game_text(line)
        peer_key = ""
        if line.startswith("PEER "):
            peer_key = line.split(" ", 2)[1]
            self._pending = [p for p in self._pending if p[2] != peer_key]
        pieces = [line[i:i + FRAGMENT_CHARS] for i in range(0, len(line), FRAGMENT_CHARS)] or [""]
        for index, piece in enumerate(pieces):
            flag = "=" if index == len(pieces) - 1 else "+"
            self._pending.append((self._next_seq, flag + piece, peer_key))
            self._next_seq += 1

    def drop_pending(self) -> None:
        """Forget unsent lines when the game they were meant for is gone. The
        sequence keeps climbing so the next game never mistakes new for old."""
        self._pending = []

    def acknowledge(self, seq: int) -> None:
        self._pending = [p for p in self._pending if p[0] > seq]

    def inbound_text(self) -> str:
        # A file may end partway through a line's fragments: the game keeps the
        # partial line across polls until its '=' fragment arrives.
        rows = self._pending[:MAX_LINES_PER_FILE]
        return "".join(f"APIn {self.session} {seq} {fragment}\r\n" for seq, fragment, _ in rows)

    def write_inbound(self) -> None:
        text = self.inbound_text()
        if text == self._written:
            return
        path = self.channel_dir / INBOUND_FILE
        temporary = path.with_suffix(".new")
        temporary.write_text(text, encoding="latin-1", errors="replace", newline="")
        try:
            os.replace(temporary, path)
        except PermissionError:
            # The game is reading the file this instant; the next poll retries.
            return
        self._written = text

    def read_outbound(self) -> "list[tuple[str, list[str]]]":
        """Every finished batch in order, as (game session, lines), deleted once read."""
        batches = []
        for entry in self.channel_dir.iterdir():
            match = OUTBOUND_PATTERN.match(entry.name)
            if match:
                batches.append((int(match.group(2)), match.group(1), entry))
        out = []
        for _, game_session, path in sorted(batches):
            try:
                raw = path.read_bytes()
                path.unlink()
            except OSError:
                break
            lines = [line.strip("\r") for line in _decode_batch(raw).split("\n")]
            out.append((game_session, [line for line in lines if line]))
        return out

    def clear_channel(self) -> None:
        """Remove a previous session's files so stale lines never replay."""
        self.channel_dir.mkdir(parents=True, exist_ok=True)
        for entry in self.channel_dir.iterdir():
            if entry.name == INBOUND_FILE or entry.name.startswith("out_"):
                try:
                    entry.unlink()
                except OSError:
                    pass

    async def run(self,
                  on_connect: Callable[["FileGameLink"], Awaitable[None]],
                  on_line: Callable[[str], Awaitable[None]],
                  on_disconnect: Callable[["FileGameLink"], Awaitable[None]]) -> None:
        self.clear_channel()
        try:
            while True:
                try:
                    await self._poll(on_connect, on_line, on_disconnect)
                except Exception:
                    # A file the game holds this instant, or a failing connect
                    # handler; the next poll retries.
                    logger.exception("Game link poll failed")
                await asyncio.sleep(POLL_SECONDS)
        finally:
            logger.info("Game link stopped")

    async def _enter_session(self, game_session: str,
                             on_connect: Callable[["FileGameLink"], Awaitable[None]],
                             on_disconnect: Callable[["FileGameLink"], Awaitable[None]]) -> None:
        """Connect on a batch from a new game session, or from the same one
        after a timeout. A new session ends the previous connection first."""
        resumed = game_session == self.game_session
        if not resumed:
            if self.connected:
                self.connected = False
                self.drop_pending()
                await on_disconnect(self)
            self.game_session = game_session
        if self.connected:
            return
        self.connected = True
        if resumed:
            # The game kept its session, so it sends no HELLO of its own; ask
            # for the handshake this client just lost.
            self.queue_line("HELLOREQ")
        await on_connect(self)

    async def _dispatch(self, lines: "list[str]", on_line: Callable[[str], Awaitable[None]]) -> None:
        for line in lines:
            if line.startswith("INACK "):
                parts = line.split()
                if len(parts) == 3 and parts[1] == self.session and parts[2].isdigit():
                    self.acknowledge(int(parts[2]))
            elif line != "ALIVE":
                try:
                    await on_line(line)
                except Exception:
                    logger.exception(f"Game line failed: {line!r}")

    async def _poll(self,
                    on_connect: Callable[["FileGameLink"], Awaitable[None]],
                    on_line: Callable[[str], Awaitable[None]],
                    on_disconnect: Callable[["FileGameLink"], Awaitable[None]]) -> None:
        now = time.monotonic()
        # Any pending line already proves the client is alive, so a PING only
        # goes out into an empty backlog.
        if now - self._last_ping >= PING_SECONDS:
            self._last_ping = now
            if not self._pending:
                self.queue_line("PING")
        self.write_inbound()

        for game_session, lines in self.read_outbound():
            self._last_batch = now
            await self._enter_session(game_session, on_connect, on_disconnect)
            await self._dispatch(lines, on_line)

        if self.connected and now - self._last_batch > GAME_TIMEOUT_SECONDS:
            self.connected = False
            self.drop_pending()
            await on_disconnect(self)
