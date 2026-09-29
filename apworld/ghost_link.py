"""Ghost players: share where each Harry Potter 2 slot's Harry is and draw the others.

The mod samples Harry ten times a second and sends a POS frame over the
bridge. GhostLink batches those samples into one AP Bounce every few hundred
milliseconds under the HP2Ghost tag, and turns Bounces from other slots into
PEER frames for the mod, replayed with the spacing the sender recorded so the
ghost moves smoothly. A peer on another map is not drawn, and a peer that
stops sending is dropped with a PEERGONE frame. Pure bookkeeping: the caller
owns the clock, the socket and the event loop.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from typing import Callable, Optional

GHOST_TAG = "HP2Ghost"
# One Bounce per this interval while the game keeps sending samples.
SEND_INTERVAL_S = 0.4
# A peer silent this long is gone. The mod heartbeats every two seconds.
PEER_TIMEOUT_S = 4.0
# Longest a replayed sample may lag its batch, so a bad offset cannot park a ghost.
MAX_REPLAY_DELAY_S = 1.0
# Most samples one Bounce may carry; anything past this is ignored.
MAX_SAMPLES_PER_BOUNCE = 20
# A sample after the map name: x y z pitch yaw roll, then the body track
# (sequence, frame, loop), the upper-body track (sequence, frame, loop), scale.
SAMPLE_FIELD_COUNT = 13
_INT_FIELDS = frozenset((0, 1, 2, 3, 4, 5, 7, 8, 10, 11))
_SCALE_FIELD = 12
_TOKEN = re.compile(r"^[A-Za-z0-9_.\-]{1,32}$")
_LEVEL = re.compile(r"^[A-Za-z0-9_\-]{1,48}$")
_MAX_NAME_CHARS = 16


def parse_sample(raw: list) -> Optional[list]:
    """Validate one sample's fields (from the mod as strings, from a Bounce as
    JSON values). Returns typed fields, or None for anything malformed."""
    if not isinstance(raw, list) or len(raw) != SAMPLE_FIELD_COUNT:
        return None
    fields: list = []
    for index, value in enumerate(raw):
        if index in _INT_FIELDS:
            if isinstance(value, bool) or isinstance(value, float):
                return None
            try:
                fields.append(int(value))
            except (TypeError, ValueError):
                return None
        elif index == _SCALE_FIELD:
            try:
                scale = float(value)
            except (TypeError, ValueError):
                return None
            if not 0.05 <= scale <= 50.0:
                return None
            fields.append(round(scale, 2))
        else:
            if not isinstance(value, str) or not _TOKEN.match(value):
                return None
            fields.append(value)
    return fields


def format_field(value) -> str:
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


def clean_name(name) -> str:
    """A slot name safe for the bar-separated PEER frame."""
    if not isinstance(name, str):
        return "?"
    cleaned = "".join(ch for ch in name if ch.isprintable() and ch != "|").strip()
    return (cleaned or "?")[:_MAX_NAME_CHARS]


@dataclass
class Peer:
    name: str
    level: str
    last_seen: float
    # True while the mod has this peer's ghost, so PEERGONE is sent once.
    visible: bool = False


class GhostLink:
    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self.enabled = False
        # Our map, from the LEVEL frame and from every POS sample.
        self.level: Optional[str] = None
        self._pending: list[tuple[float, list]] = []
        self._last_send = float("-inf")
        self.peers: dict[int, Peer] = {}

    # Outbound: our Harry.

    def on_pos(self, payload: str) -> list[str]:
        """Take one POS payload from the mod. Returns the PEERGONE lines a map
        change reveals, since peers left on the old map stop being drawn."""
        parts = payload.split("|")
        if len(parts) != SAMPLE_FIELD_COUNT + 1 or not _LEVEL.match(parts[0]):
            return []
        fields = parse_sample(parts[1:])
        if fields is None:
            return []
        gone = self.set_level(parts[0])
        if not self.enabled:
            return gone
        self._pending.append((self._clock(), fields))
        # A stalled pump (ghosts just turned on, the server away) must not
        # pile up a backlog: only the newest window is worth sending.
        del self._pending[:-MAX_SAMPLES_PER_BOUNCE]
        return gone

    def set_level(self, level: Optional[str]) -> list[str]:
        if level == self.level:
            return []
        self.level = level
        # Samples from the old map would be labelled with the new one.
        self._pending.clear()
        gone = []
        for slot, peer in self.peers.items():
            if peer.visible and peer.level != level:
                peer.visible = False
                gone.append(f"PEERGONE {slot}")
        return gone

    def bounce_due(self, slot: int, name: str, now: Optional[float] = None) -> Optional[dict]:
        """The Bounce data to send now, or None. Samples carry their offset from
        the first one so the receiver can replay them with the same spacing."""
        if not self.enabled or self.level is None or not self._pending:
            return None
        now = self._clock() if now is None else now
        if now - self._last_send < SEND_INTERVAL_S:
            return None
        first = self._pending[0][0]
        samples = [[round(stamp - first, 2), *fields] for stamp, fields in self._pending]
        self._pending.clear()
        self._last_send = now
        return {"src": slot, "name": clean_name(name), "lv": self.level, "s": samples}

    # Inbound: other players.

    def on_bounced(self, data, my_slot: Optional[int], now: Optional[float] = None) -> list[tuple[float, str]]:
        """Turn one HP2Ghost Bounce into (delay, line) pairs for the mod. Our own
        echo, malformed data and peers on another map produce no PEER lines."""
        if not self.enabled or not isinstance(data, dict):
            return []
        src = data.get("src")
        level = data.get("lv")
        raw_samples = data.get("s")
        if isinstance(src, bool) or not isinstance(src, int) or src == my_slot:
            return []
        if not isinstance(level, str) or not isinstance(raw_samples, list):
            return []
        now = self._clock() if now is None else now
        name = clean_name(data.get("name"))
        peer = self.peers.get(src)
        if peer is None:
            peer = Peer(name, level, now)
            self.peers[src] = peer
        peer.name = name
        peer.level = level
        peer.last_seen = now
        if level != self.level:
            if peer.visible:
                peer.visible = False
                return [(0.0, f"PEERGONE {src}")]
            return []
        lines: list[tuple[float, str]] = []
        for entry in raw_samples[:MAX_SAMPLES_PER_BOUNCE]:
            if not isinstance(entry, list) or len(entry) != SAMPLE_FIELD_COUNT + 1:
                continue
            try:
                delay = float(entry[0])
            except (TypeError, ValueError):
                continue
            fields = parse_sample(entry[1:])
            if fields is None:
                continue
            delay = min(max(delay, 0.0), MAX_REPLAY_DELAY_S)
            body = "|".join([str(src), name, *(format_field(v) for v in fields)])
            lines.append((delay, "PEER " + body))
        if lines:
            peer.visible = True
        return lines

    def should_replay(self, src: int, level: Optional[str]) -> bool:
        """Whether a sample scheduled earlier for `src` on `level` is still
        worth drawing: ghosts on, still that map, and the peer still drawn."""
        peer = self.peers.get(src)
        return self.enabled and self.level == level and peer is not None and peer.visible

    def sweep(self, now: Optional[float] = None) -> list[str]:
        """Forget peers that went silent. Returns their PEERGONE lines."""
        now = self._clock() if now is None else now
        gone = []
        for slot in [s for s, p in self.peers.items() if now - p.last_seen > PEER_TIMEOUT_S]:
            if self.peers[slot].visible:
                gone.append(f"PEERGONE {slot}")
            del self.peers[slot]
        return gone

    def forget_all(self) -> list[str]:
        """Drop every peer and pending sample (ghosts turned off)."""
        gone = [f"PEERGONE {slot}" for slot, peer in self.peers.items() if peer.visible]
        self.peers.clear()
        self._pending.clear()
        return gone

    def reset_visible(self) -> None:
        """The game reconnected with a fresh level: no ghost exists there yet."""
        for peer in self.peers.values():
            peer.visible = False
