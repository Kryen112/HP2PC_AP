"""HP2PC_AP — Archipelago-aware sidecar.

Subclasses Archipelago's CommonContext to speak the real AP protocol over
WebSocket against a hosted seed, while also accepting a local TCP connection
from the HP2 mod and bridging messages between the two.

Usage (Stefan's Windows PC):
    cd "C:\\Users\\kryen\\Documents\\Archipelago-play\\Archipelago"
    py -3.12 "C:\\Users\\kryen\\Documents\\Archipelago-play\\Harry Potter 2 PC\\HP2PC_AP\\client\\hp2_ap_client.py" \\
        --name HP2_Test --connect localhost:38281 --password ""

The script imports Archipelago/CommonClient from the cwd, so it must be run
from inside the Archipelago repo (or with that directory on sys.path).

Mod-side protocol (newline-delimited text):
    HELLO                       (game → sidecar, on connect)
    CHECK <id>                  (game → sidecar, on pickup)
    GRANT <classname>           (sidecar → game, on item received)

AP-side protocol: standard Archipelago WebSocket (handled by CommonContext).
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys
from pathlib import Path
from typing import Optional

# Bootstrap: make sure Archipelago is importable. Try a couple of locations:
# (1) sibling of HP2PC_AP/'s parent (Archipelago-play/Archipelago/) and
# (2) the current working directory (e.g. when invoked from inside Archipelago).
import os

_HERE = Path(__file__).resolve()
_CANDIDATES = [
    _HERE.parent.parent.parent.parent / "Archipelago",
    Path(os.getcwd()),
]
for _c in _CANDIDATES:
    if (_c / "CommonClient.py").is_file():
        if str(_c) not in sys.path:
            sys.path.insert(0, str(_c))
        break
else:
    raise RuntimeError(
        "Cannot find Archipelago framework. Tried: "
        + ", ".join(str(c) for c in _CANDIDATES)
        + ". Either run this script from inside the Archipelago repo, or ensure "
          "Archipelago lives at ../../Archipelago relative to this client."
    )

import CommonClient
from CommonClient import CommonContext, ClientCommandProcessor, get_base_parser, server_loop, gui_enabled
from NetUtils import ClientStatus

# Pull data tables from our apworld so the sidecar uses the same canonical
# mappings as the AP framework / generator.
from worlds.harry_potter_2.locations import (
    CARD_CLASS_TO_LOCATION_NAME,
    CARD_GAME_ID_TO_LOCATION_NAME,
    LOCATION_NAME_TO_ID,
)
from worlds.harry_potter_2.items import CARD_CLASS_TO_ITEM_NAME

ITEM_NAME_TO_CARD_CLASS = {item_name: ucls for ucls, item_name in CARD_CLASS_TO_ITEM_NAME.items()}

# Build UScript class → game-side card Id by composing the two maps:
#   CARD_GAME_ID_TO_LOCATION_NAME  (game_id → "Card_Foo")
#   CARD_CLASS_TO_LOCATION_NAME    ("WCFoo" → "Card_Foo")
_LOC_NAME_TO_CLASS = {loc: cls for cls, loc in CARD_CLASS_TO_LOCATION_NAME.items()}
CARD_CLASS_TO_GAME_ID = {
    _LOC_NAME_TO_CLASS[loc_name]: game_id
    for game_id, loc_name in CARD_GAME_ID_TO_LOCATION_NAME.items()
}

GAME_NAME = "Harry Potter 2"
GAME_TCP_HOST = "127.0.0.1"
GAME_TCP_PORT = 38281

logger = logging.getLogger("HP2Client")


class HP2CommandProcessor(ClientCommandProcessor):
    pass


class HP2Context(CommonContext):
    game = GAME_NAME
    command_processor = HP2CommandProcessor
    items_handling = 0b111  # receive starting inventory + own items + remote items
    want_slot_data = False

    def __init__(self, server_address: Optional[str], password: Optional[str]):
        super().__init__(server_address, password)
        self.game_writer: Optional[asyncio.StreamWriter] = None
        self.tcp_server_task: Optional[asyncio.Task] = None
        self.checked_locations_seen: set[int] = set()
        # Card game-Ids the sidecar has just GRANTed to the mod; the mod's
        # watcher will see those cards become Harry-owned and echo CHECK back.
        # We swallow those echoes so they don't trigger another LocationCheck.
        self.granted_card_game_ids: set[int] = set()

    async def server_auth(self, password_requested: bool = False) -> None:
        if password_requested and not self.password:
            await super().server_auth(password_requested)
        await self.get_username()
        await self.send_connect()

    def on_package(self, cmd: str, args: dict) -> None:
        if cmd == "Connected":
            logger.info(f"Connected to AP server as slot {self.slot} ({self.player_names.get(self.slot, '?')})")
        elif cmd == "ReceivedItems":
            for item in args.get("items", []):
                # item is a NetworkItem namedtuple: (item, location, player, flags)
                item_id = item.item
                item_name = self.item_names.lookup_in_game(item_id, GAME_NAME) or f"item_id_{item_id}"
                # Cards: forward as 'GRANT <UScriptClassName>' so mod's ApplyGrant
                # can DynamicLoadObject and Spawn-Touch the card. Non-cards get
                # the raw item name; mod's ApplyGrant ignores those for now.
                ucls = ITEM_NAME_TO_CARD_CLASS.get(item_name)
                payload = ucls if ucls else item_name
                if ucls:
                    game_id = CARD_CLASS_TO_GAME_ID.get(ucls)
                    if game_id is not None:
                        # Tell ourselves: when the mod echoes CHECK <game_id>
                        # back (because its watcher sees Harry now owns this
                        # card), do NOT treat it as a real check.
                        self.granted_card_game_ids.add(game_id)
                logger.info(f"Received item: {item_name} (id={item_id}) → forwarding as GRANT {payload}")
                self._send_to_game(f"GRANT {payload}")

    def run_gui(self) -> None:
        # CLI-only for now; CommonContext supports GUI but we keep it minimal.
        pass

    def _send_to_game(self, text: str) -> None:
        if self.game_writer is None or self.game_writer.is_closing():
            logger.warning(f"Cannot send to game (no connection): {text}")
            return
        try:
            self.game_writer.write((text + "\n").encode("utf-8"))
        except Exception as e:
            logger.exception(f"Failed to write to game: {e}")

    async def handle_game_connection(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        logger.info(f"Game connected from {peer}")
        self.game_writer = writer
        try:
            while True:
                line_bytes = await reader.readline()
                if not line_bytes:
                    break
                line = line_bytes.decode("utf-8", errors="replace").rstrip("\r\n")
                logger.info(f"[game→sidecar] {line}")
                await self._handle_game_line(line)
        finally:
            logger.info(f"Game disconnected ({peer})")
            self.game_writer = None
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

    async def _handle_game_line(self, line: str) -> None:
        if line == "HELLO":
            return
        if line.startswith("CHECK_SPELL "):
            spell_name = line[len("CHECK_SPELL "):].strip()
            # M5: spells detected but no AP location mapping yet (classroom →
            # spell mapping needs playtest data; lands in M6). Just log and
            # ignore for now.
            logger.info(f"Game learned spell {spell_name!r} — no AP location mapping yet, not sending LocationChecks")
            return
        if line.startswith("CHECK_KEYITEM "):
            key_item_name = line[len("CHECK_KEYITEM "):].strip()
            # Same story as spells: location mapping (which level the key item
            # is in) needs playtest data, M6.
            logger.info(f"Game picked up key item {key_item_name!r} — no AP location mapping yet, not sending LocationChecks")
            return
        if line.startswith("CHECK "):
            try:
                check_id = int(line[6:].strip())
            except ValueError:
                logger.warning(f"Unparseable CHECK: {line!r}")
                return
            if not self.server or self.slot is None:
                logger.warning(f"AP server not connected (slot={self.slot}), dropping CHECK {check_id}")
                return
            if check_id in self.granted_card_game_ids:
                logger.info(f"Ignoring CHECK {check_id} — sidecar just GRANTed this card; watcher echo")
                return
            location_name = CARD_GAME_ID_TO_LOCATION_NAME.get(check_id)
            if location_name is None:
                logger.warning(f"Game CHECK {check_id} doesn't map to a known card location; dropping")
                return
            location_id = LOCATION_NAME_TO_ID.get(location_name)
            if location_id is None:
                logger.warning(f"Card location {location_name!r} has no AP id; dropping")
                return
            if location_id in self.checked_locations_seen:
                return
            self.checked_locations_seen.add(location_id)
            await self.send_msgs([{"cmd": "LocationChecks", "locations": [location_id]}])
            logger.info(f"Sent LocationChecks for {location_name} (id={location_id}, game CHECK {check_id})")

    async def run_tcp_server(self) -> None:
        server = await asyncio.start_server(
            self.handle_game_connection, GAME_TCP_HOST, GAME_TCP_PORT
        )
        sockets = ", ".join(str(s.getsockname()) for s in server.sockets)
        logger.info(f"Game-side TCP listener up on {sockets}")
        async with server:
            await server.serve_forever()


async def main_async(args: argparse.Namespace) -> None:
    ctx = HP2Context(args.connect, args.password)
    ctx.auth = args.name
    ctx.server_task = asyncio.create_task(server_loop(ctx), name="ap server loop")
    ctx.tcp_server_task = asyncio.create_task(ctx.run_tcp_server(), name="game tcp server")
    ctx.run_cli()
    await ctx.exit_event.wait()
    await ctx.shutdown()


def main() -> None:
    parser = get_base_parser(description="HP2 Archipelago client (sidecar bridge to HP2 mod).")
    parser.add_argument("--name", default=None, help="AP slot name to connect as.")
    parser.add_argument("url", nargs="?", help="Archipelago connection url.")
    args = parser.parse_args()
    args = CommonClient.handle_url_arg(args, parser=parser)
    logging.getLogger().setLevel(logging.INFO)
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
