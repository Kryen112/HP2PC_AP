"""HP2PC_AP — Archipelago-aware client (bundled apworld component).

Subclasses Archipelago's CommonContext to speak the real AP protocol over
WebSocket against a hosted seed, while also accepting a local TCP connection
from the HP2 mod and bridging messages between the two.

Launched via the Archipelago launcher's "HP2 PC Client" button, or directly
during dev from inside the Archipelago repo:
    py -3.12 -m worlds.harry_potter_2_pc.Client --name HP2_Test --connect localhost:38281

Mod-side protocol (newline-delimited text):
    HELLO                       (game → client, on connect)
    CHECK <id>                  (game → client, on card pickup — game-side card id 1..101)
    CHECK_LOCID <id>            (game → client, on secret/star pickup — raw AP location id)
    CHECK_SPELL <name>          (game → client, on spell learned)
    CHECK_KEYITEM <name>        (game → client, on Boomslang/Bicorn pickup or BitOGoyle interaction)
    GOAL_COMPLETE               (game → client, once when post-Basilisk credits start)
    RINGOUT <signed_int>        (game → client, local bean total changed organically)
    GRANT <classname>           (client → game, on item received)
    RINGIN <signed_int>         (client → game, net remote RingLink delta to apply)

AP-side protocol: standard Archipelago WebSocket (handled by CommonContext).
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import random
import sys
import time
import warnings
from typing import Optional

# Silence the upstream setuptools deprecation that fires every time AP imports
# pkg_resources (Archipelago/ModuleUpdate.py:76). Must run before importing
# CommonClient below so the filter is in place when the warning would emit.
warnings.filterwarnings("ignore", message=".*pkg_resources is deprecated.*")

import CommonClient
from CommonClient import CommonContext, ClientCommandProcessor, get_base_parser, server_loop, gui_enabled
from NetUtils import ClientStatus

from .locations import (
    CARD_CLASS_TO_LOCATION_NAME,
    CARD_GAME_ID_TO_LOCATION_NAME,
    LOCATION_NAME_TO_ID,
)
from .items import CARD_CLASS_TO_ITEM_NAME, FILLER_NAMES, ITEM_GROUPS

ITEM_NAME_TO_CARD_CLASS = {item_name: ucls for ucls, item_name in CARD_CLASS_TO_ITEM_NAME.items()}
# Trap item names, from ITEM_GROUPS so it can never drift from
# data/items.yaml. Used both for non-durability and appearance.
TRAP_ITEM_NAMES = frozenset(ITEM_GROUPS.get("Traps", []))
# Items the mod must NOT have replayed to it on a HELLO/reconnect durable
# resync. Beans are non-durable because RingLink owns the bean total. Traps
# are one-shot by definition — without this every reconnect would re-fire
# every trap ever received (re-stealing beans, re-clearing the spellbook, etc.).
NON_DURABLE_ITEM_NAMES = {
    "Small Pile of Beans", "Medium Pile of Beans", "Large Pile of Beans",
} | set(TRAP_ITEM_NAMES)

# Build UScript class → game-side card Id by composing the two maps:
#   CARD_GAME_ID_TO_LOCATION_NAME  (game_id → "Card_Foo")
#   CARD_CLASS_TO_LOCATION_NAME    ("WCFoo" → "Card_Foo")
_LOC_NAME_TO_CLASS = {loc: cls for cls, loc in CARD_CLASS_TO_LOCATION_NAME.items()}
CARD_CLASS_TO_GAME_ID = {
    _LOC_NAME_TO_CLASS[loc_name]: game_id
    for game_id, loc_name in CARD_GAME_ID_TO_LOCATION_NAME.items()
}

GAME_NAME = "Harry Potter 2 PC"
GAME_TCP_HOST = "127.0.0.1"
GAME_TCP_PORT = 38281

# Map UScript spell name (as fired by APCardWatcher's CHECK_SPELL) to the
# AP location it represents. Lumos/Flipendo/Alohomora are starter cutscene
# spells with no classroom — they get placed as start-inventory by the seed
# and never fire CHECK_SPELL after the initial-snapshot baseline. The 4
# below are the non-starter spells, each taught after its classroom's spell
# challenge. Story order: Rictusempra (Lockhart#1) → Skurge (Flitwick) →
# Diffindo (Sprout) → Spongify (Lockhart#2). See data/locations.yaml.
SPELL_TO_LOCATION_NAME = {
    "Rictusempra": "Learned Rictusempra",
    "Skurge":      "Learned Skurge",
    "Diffindo":    "Learned Diffindo",
    "Spongify":    "Learned Spongify",
}

# Map UScript special progression name to its AP check. v1: empty — Boomslang,
# Bicorn, and BitOGoyle are not randomized, they flow through vanilla story.
# The watcher still fires CHECK_KEYITEM when it sees a vanilla pickup; the
# client's _send_named_location_check then logs "no AP location mapping" and
# silently skips. Add entries back when these become AP checks again.
KEYITEM_TO_LOCATION_NAME: dict[str, str] = {}

# #3 marker appearance. The client scouts every HP2 location, resolves what
# item each holds, and pushes a per-location appearance code the mod uses to
# morph the marker into that item's vanilla art. Codes mirror
# APCardWatcher.AppearanceCode[] / plans/03-marker-appearance-by-owner.md.

# Spell appearance index — MUST match APCardWatcher.SpellNames[] order
# (0 Alohomora … 6 Spongify). Appearance code = 1000 + index.
SPELL_NAME_TO_INDEX = {
    "Alohomora": 0, "Diffindo": 1, "Flipendo": 2, "Lumos": 3,
    "Rictusempra": 4, "Skurge": 5, "Spongify": 6,
}

# Filler appearance code — FILLER_NAMES order maps 1:1 to the mod's 2001..2008
# (Small/Medium/Large/Massive Beans, Wiggenweld, Wiggentree Bark, Flobberworm,
# Chocolate Frog).
FILLER_CODE = {name: 2001 + i for i, name in enumerate(FILLER_NAMES)}

# Equipment appearance code — vanilla HProp pickups morphed to their own
# vanilla mesh, same as cards/spells/filler (mod codes 3001..3002).
EQUIPMENT_CODE = {'Nimbus 2001': 3001, 'Quidditch Armour': 3002}

# Bingo key appearance code — the 13 level/challenge bookcase keys all share
# the vanilla "silver key" FX sprite (mod code 3003). Sourced from the
# canonical ITEM_GROUPS entry so the set never drifts from items.yaml.
KEY_CODE = {name: 3003 for name in ITEM_GROUPS['Bingo Keys']}

# Foreign (non-HP2) item codes — the only surviving #1 contribution: the
# AP-logo plate, arrow variant when the foreign item is progression or trap
# (progression_skip_balancing collapses to the progression bit), plain
# otherwise. This is the sole place the classification arrow is computed.
APPEARANCE_FOREIGN_PLAIN = 9000
APPEARANCE_FOREIGN_ARROW = 9001

logger = logging.getLogger("HP2Client")


def _log_safe(text: str, limit: int = 180) -> str:
    """Truncate a payload for logging only. The AP Kivy client renders every
    INFO line into an on-screen log widget; a single multi-KB line (the #3
    APPEARANCE table is ~6.5 KB) stalls Kivy's text layout and hangs the
    asyncio event loop for over a minute. The full text is still sent to the
    game unchanged — this shortens what is written to the log."""
    if len(text) <= limit:
        return text
    return f"{text[:limit]}… [+{len(text) - limit} more chars]"


class HP2CommandProcessor(ClientCommandProcessor):
    pass


class HP2Context(CommonContext):
    game = GAME_NAME
    command_processor = HP2CommandProcessor
    items_handling = 0b111  # receive starting inventory + own items + remote items
    want_slot_data = True  # bingo Great Hall key thresholds ride slot_data

    def __init__(self, server_address: Optional[str], password: Optional[str]):
        super().__init__(server_address, password)
        self.game_writer: Optional[asyncio.StreamWriter] = None
        self.tcp_server_task: Optional[asyncio.Task] = None
        self.checked_locations_seen: set[int] = set()
        # Dedupe GOAL_COMPLETE: once the mod has reported the goal we track it as
        # "claimed" regardless of whether the AP send succeeded — the actual
        # delivery to AP lives in pending_ap_outbound below, which retries on
        # reconnect. Prevents the mod's WasInEndGame guard re-firing across
        # save-load from re-queueing.
        self.goal_sent: bool = False
        # FIFO of GRANT lines accumulated while no game is connected (start
        # inventory delivered before game boot, mid-session game crash, etc).
        # Drained by handle_game_connection on each new game connect.
        self.pending_grants: list[str] = []
        # Durable items (cards/spells/key items) that should be replayed to the
        # game when it reconnects or loads an earlier save. Excludes bean filler,
        # because replaying filler would duplicate a consumable/spendable state.
        self.durable_grants: list[Optional[str]] = []
        # Outbound AP messages queued while the AP server is offline. Drained
        # on every successful Connected. In-memory only — a client crash
        # during an AP outage loses these. Disk persistence is parked for v2
        # alongside bean durability (see ../DESIGN.md#v2-parking-lot).
        self.pending_ap_outbound: list[dict] = []
        # Per-game-session set of GRANT/SENT lines successfully written to the
        # game writer. Reset every time a new game connects (handle_game_connection).
        # Used by _resync_durable_grants on HELLO to skip items that were
        # already delivered earlier in this session — without it, the very
        # first HELLO of a new seed would replay every item on top of the
        # initial ReceivedItems delivery (3 starter spells × 2 = 6 toasts).
        self.delivered_to_game: set[str] = set()
        # Last seed_name observed via RoomInfo. On change, wipe seed-specific
        # state in _handle_seed_change so a long-running client targeting the
        # same host:port across seeds doesn't replay seed A's items to seed B.
        # CommonContext.reset_server_state is NOT the right hook — it runs on
        # every disconnect, including transient AP blips, and the whole point
        # of durable_grants is to survive those.
        self._last_seed_name: Optional[str] = None
        # Bingo Great Hall key config as the "GOALCFG c,s,l,d,q,mask" payload,
        # or None for vanilla / not-yet-received. Parsed from slot_data on
        # Connected; pushed to the mod on every game HELLO (sticky + idempotent
        # mod-side, so a fresh game launch / reconnect re-arms it).
        self.bingo_goalcfg: Optional[str] = None
        # #3: last "apId:code,…" appearance payload pushed to the mod, or None
        # if not yet built. Resent on every game HELLO (sticky + idempotent
        # mod-side). Rebuilt from self.locations_info on each LocationInfo.
        self.appearance_csv: Optional[str] = None
        # RingLink (#5). Enabled per-slot via slot_data on Connected. ring_source
        # is a per-connection random int UUID, re-rolled every Connected, used
        # as the Bounce `source` field and as the self-filter key so the
        # server's echo of our own Bounce is dropped. Replaces a slot-name key
        # so co-op-on-one-slot links and SA2/SMW interop both work.
        self.ring_link_enabled: bool = False
        self.ring_source: Optional[int] = None

    async def server_auth(self, password_requested: bool = False) -> None:
        if password_requested and not self.password:
            await super().server_auth(password_requested)
        await self.get_username()
        await self.send_connect()

    def on_package(self, cmd: str, args: dict) -> None:
        if cmd == "RoomInfo":
            new_seed = args.get("seed_name")
            if self._last_seed_name and new_seed and new_seed != self._last_seed_name:
                self._handle_seed_change(self._last_seed_name, new_seed)
            if new_seed:
                self._last_seed_name = new_seed
        elif cmd == "Connected":
            logger.info(f"Connected to AP server as slot {self.slot} ({self.player_names.get(self.slot, '?')})")
            if self.pending_ap_outbound:
                asyncio.create_task(self._flush_pending_ap_outbound())
            sd = args.get("slot_data") or {}
            if sd.get("game_mode") == "bingo":
                self.bingo_goalcfg = "{},{},{},{},{},{}".format(
                    sd.get("bingo_goal_cards", 0),
                    sd.get("bingo_goal_spells", 0),
                    sd.get("bingo_goal_levels", 0),
                    sd.get("bingo_goal_duels", 0),
                    sd.get("bingo_goal_quidditch", 0),
                    sd.get("bingo_level_mask", 0),
                )
                logger.info(f"Bingo goal config from slot_data: {self.bingo_goalcfg}")
                # If the game is already connected, push now; otherwise it goes
                # out on the next game HELLO.
                if self.game_writer is not None:
                    self._send_to_game("GOALCFG " + self.bingo_goalcfg)
            else:
                self.bingo_goalcfg = None

            # RingLink (#5). Re-roll the per-connection source UUID and
            # (re)register the tag on every Connected so a reconnect stays
            # routable for Bounced packets. Disable cleanly if a later seed
            # / reconnect turns it off.
            if sd.get("ring_link"):
                asyncio.create_task(self._enable_ring_link())
            else:
                if self.ring_link_enabled:
                    logger.info("RingLink disabled for this slot")
                self.ring_link_enabled = False
                self.ring_source = None

            # #3: scout this slot's HP2 locations so the appearance table can
            # resolve what item each marker holds. create_as_hint=0 → peek
            # only, no hint broadcast (no spoiler-policy issue).
            #
            # MUST intersect with server_locations: LOCATION_NAME_TO_ID is the
            # full cross-mode/all-options universe, but a bingo / option-
            # trimmed seed only instantiates a subset for this slot. Scouting a
            # location id the slot doesn't have raises a server-side KeyError
            # that drops the connection — and CommonClient auto-resends
            # locations_scouted on every reconnect, so a bad entry would wedge
            # the client permanently. server_locations (missing | checked) is
            # the authoritative per-slot set and is populated before
            # on_package runs.
            scout_ids = sorted(
                set(LOCATION_NAME_TO_ID.values()) & set(self.server_locations)
            )
            if scout_ids:
                self.locations_scouted |= set(scout_ids)
                asyncio.create_task(self._send_or_queue_ap_msg(
                    {"cmd": "LocationScouts",
                     "locations": scout_ids,
                     "create_as_hint": 0},
                    label=f"LocationScouts ({len(scout_ids)} HP2 locations, "
                          f"#3 appearance, no hint)",
                ))
        elif cmd == "ReceivedItems":
            package_index = args.get("index")
            for item in args.get("items", []):
                # item is a NetworkItem namedtuple: (item, location, player, flags)
                item_id = item.item
                item_name = self.item_names.lookup_in_game(item_id, GAME_NAME) or f"item_id_{item_id}"
                # Cards: forward as 'GRANT <UScriptClassName>' so mod's ApplyGrant
                # can DynamicLoadObject the card class and SetCardOwner. Non-cards
                # get the raw item name and route through ApplyGrant's spell /
                # key-item / beans branches.
                ucls = ITEM_NAME_TO_CARD_CLASS.get(item_name)
                payload = ucls if ucls else item_name
                # Sender's slot name for the HUD toast ("from <sender>"). For
                # items the seed placed in your own world, sender == self.slot
                # (i.e. shows your own name — matches AP client UX). Mod's
                # ApplyGrant parses the pipe-separated form back out;
                # legacy mod builds without the parse just see the full
                # `<payload>|<sender>` as the item name and fall through to
                # the unknown-item branch. To keep the durable resync
                # backward-compatible, store with sender so a later resync
                # round-trips identically.
                sender_name = self.player_names.get(item.player, f"player_{item.player}")
                payload_with_sender = f"{payload}|{sender_name}"
                if item_name not in NON_DURABLE_ITEM_NAMES:
                    self._remember_durable_grant(payload_with_sender, package_index)
                logger.info(f"Received item: {item_name} (id={item_id}) from {sender_name} → forwarding as GRANT {payload_with_sender}")
                self._send_to_game(f"GRANT {payload_with_sender}")
                if isinstance(package_index, int):
                    package_index += 1
        elif cmd == "LocationInfo":
            # CommonContext's built-in handler has already populated
            # self.locations_info[loc] = NetworkItem for every scouted
            # location before on_package runs. Rebuild + push the table.
            self._rebuild_appearance_table()
        elif cmd == "Bounced":
            self._handle_ring_bounce(args)

    def _handle_ring_bounce(self, args: dict) -> None:
        """Apply an inbound RingLink Bounce to the game's bean total.

        Inbound is NOT cached (§4): if the game is offline the delta is
        dropped, bypassing _send_to_game's offline queue — replaying stale
        ring deltas after an outage double-applies across the room and beans
        are filler. The only defer is the short mod-side PendingRingDelta,
        cleared on save/level-load boundaries.
        """
        if not self.ring_link_enabled:
            return
        if "RingLink" not in (args.get("tags") or []):
            return
        data = args.get("data") or {}
        # The server echoes our own Bounce back to us (true in stock AP); the
        # source self-filter is mandatory. Other RingLink games may send a
        # non-int source — a failed int() means it isn't ours, so apply it.
        src = data.get("source")
        if src is not None and self.ring_source is not None:
            try:
                if int(src) == self.ring_source:
                    return
            except (TypeError, ValueError):
                pass
        try:
            amount = int(data.get("amount", 0))
        except (TypeError, ValueError):
            return
        if amount == 0:
            return
        if self.game_writer is None or self.game_writer.is_closing():
            logger.info(f"RingLink: dropping inbound {amount:+d} (game offline, not cached)")
            return
        try:
            self.game_writer.write(f"RINGIN {amount}\n".encode("utf-8"))
            logger.info(f"RingLink: inbound {amount:+d} → RINGIN")
        except Exception as e:
            logger.warning(f"RingLink: failed to forward inbound {amount:+d}, dropping: {e}")

    def on_print_json(self, args: dict) -> None:
        # Toast feedback for items WE send to other slots ("Sent X to Y").
        # AP server broadcasts an ItemSend PrintJSON for every cross-slot
        # delivery; we filter to ones where item.player == self.slot (we're
        # the sender). Skip if receiving == self.slot — that's our own item
        # and ReceivedItems already triggers a "Received X from Y" toast,
        # so a SENT toast on top would be a duplicate per Stefan's spec.
        try:
            if args.get("type") == "ItemSend":
                item = args.get("item")
                receiving_slot = args.get("receiving")
                if (
                    item is not None
                    and receiving_slot is not None
                    and item.player == self.slot
                    and receiving_slot != self.slot
                ):
                    receiver_name = self.player_names.get(receiving_slot, f"player_{receiving_slot}")
                    item_name = self.item_names.lookup_in_slot(item.item, receiving_slot) or f"item_{item.item}"
                    logger.info(f"Sent item: {item_name} → {receiver_name} (slot {receiving_slot})")
                    self._send_to_game(f"SENT {item_name}|{receiver_name}")
        except Exception as e:
            logger.exception(f"on_print_json: failed to handle ItemSend: {e}")
        super().on_print_json(args)

    def make_gui(self) -> "type[kvui.GameManager]":
        from kvui import GameManager

        class HP2Manager(GameManager):
            base_title = "Archipelago Harry Potter 2 PC Client"

        return HP2Manager

    async def _enable_ring_link(self) -> None:
        # Re-roll the per-connection source UUID every Connected (reconnect-
        # safe). The tag must persist on self.tags so the Connect sent during
        # auth on a later reconnect already carries it; a ConnectUpdate is
        # only needed the first time we add it mid-session. AP 0.6.5's
        # CommonContext has NO update_tags() — mirror update_death_link
        # (CommonClient.py:752-760): mutate self.tags, then ConnectUpdate.
        self.ring_link_enabled = True
        self.ring_source = random.getrandbits(31)
        newly_tagged = "RingLink" not in self.tags
        self.tags = set(self.tags) | {"RingLink"}
        if newly_tagged and self.server and not self.server.socket.closed:
            try:
                await self.send_msgs([{"cmd": "ConnectUpdate", "tags": self.tags}])
            except Exception as e:
                logger.exception(f"RingLink: ConnectUpdate(tags) failed, inbound deltas won't route: {e}")
                return
        logger.info(f"RingLink enabled (source={self.ring_source}); RingLink tag registered")

    def _send_to_game(self, text: str) -> None:
        if self.game_writer is None or self.game_writer.is_closing():
            self.pending_grants.append(text)
            logger.info(f"Queued (no game connection yet, {len(self.pending_grants)} pending): {_log_safe(text)}")
            return
        try:
            self.game_writer.write((text + "\n").encode("utf-8"))
            self.delivered_to_game.add(text)
        except Exception as e:
            logger.exception(f"Failed to write to game, re-queuing: {e}")
            self.pending_grants.append(text)

    async def handle_game_connection(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        logger.info(f"Game connected from {peer}")
        self.game_writer = writer
        # Fresh game session — clear the per-session "already delivered" set so
        # _resync_durable_grants on HELLO knows nothing has been delivered yet.
        self.delivered_to_game = set()

        # Drain anything queued while the game wasn't connected (start
        # inventory grants delivered before game boot, items received during
        # a previous game-disconnect window, etc).
        if self.pending_grants:
            logger.info(f"Draining {len(self.pending_grants)} queued grant(s) to game")
            queued, self.pending_grants = self.pending_grants, []
            for line in queued:
                try:
                    writer.write((line + "\n").encode("utf-8"))
                    self.delivered_to_game.add(line)
                except Exception as e:
                    logger.exception(f"Failed to drain {line!r}, re-queuing remainder: {e}")
                    # Stash this one and everything after back at the queue head
                    idx = queued.index(line)
                    self.pending_grants = queued[idx:] + self.pending_grants
                    return

        try:
            while True:
                line_bytes = await reader.readline()
                if not line_bytes:
                    break
                line = line_bytes.decode("utf-8", errors="replace").rstrip("\r\n")
                logger.info(f"[game→client] {line}")
                await self._handle_game_line(line)
        except (ConnectionResetError, ConnectionAbortedError):
            # Normal on Windows when the game window closes — the OS resets
            # the socket without a clean FIN. No need to log a stack trace.
            pass
        finally:
            logger.info(f"Game disconnected ({peer})")
            # Only clear game_writer if it's still OUR writer. On Windows
            # ProactorEventLoop the previous game's readline can wake up
            # *after* a new game has already connected and replaced
            # self.game_writer; clobbering it here would strand the new
            # connection until client restart.
            if self.game_writer is writer:
                self.game_writer = None
            try:
                writer.close()
            except Exception:
                pass
            # Skip wait_closed() entirely — on Windows ProactorEventLoop, an
            # already-reset socket raises ConnectionResetError from the loop's
            # internal _loop_reading task, which asyncio surfaces as
            # "Unhandled exception in client_connected_cb" regardless of any
            # try/except we wrap around it. close() alone is sufficient for
            # cleanup; the OS reaps the socket either way.

    async def _handle_game_line(self, line: str) -> None:
        if line == "HELLO":
            self._resync_durable_grants()
            # Re-arm the bingo Great Hall key thresholds. Sticky + idempotent
            # mod-side, so resending every HELLO covers fresh game launches and
            # reconnects without harm. No-op for vanilla / pre-Connected.
            if self.bingo_goalcfg:
                self._send_to_game("GOALCFG " + self.bingo_goalcfg)
            # #3: re-push the appearance table. Sticky + idempotent mod-side,
            # so resending every HELLO re-arms a fresh game launch / reconnect.
            # is not None (not truthiness) so an all-native "" still re-arms.
            if self.appearance_csv is not None:
                self._send_to_game("APPEARANCE " + self.appearance_csv)
            return
        if line == "GOAL_COMPLETE":
            if self.goal_sent:
                return
            self.goal_sent = True
            await self._send_or_queue_ap_msg(
                {"cmd": "StatusUpdate", "status": ClientStatus.CLIENT_GOAL},
                label="ClientStatus.CLIENT_GOAL (slot complete)",
            )
            return
        if line.startswith("RINGOUT "):
            if not self.ring_link_enabled or self.ring_source is None:
                return
            try:
                delta = int(line[len("RINGOUT "):].strip())
            except ValueError:
                logger.warning(f"Unparseable RINGOUT: {line!r}")
                return
            if delta == 0:
                return
            # Do NOT route through the AP-outage replay queue
            # (pending_ap_outbound): replaying stale ring deltas after a long
            # outage double-applies across the room. If AP is down, drop the
            # delta — beans are filler; the baseline has already moved, so it
            # is a one-time small desync, not corruption.
            if not (self.server and self.slot is not None):
                logger.info(f"RingLink: AP offline, dropping outbound {delta:+d} (not queued)")
                return
            try:
                await self.send_msgs([{
                    "cmd": "Bounce",
                    "tags": ["RingLink"],
                    "data": {"time": time.time(), "amount": int(delta),
                             "source": self.ring_source},
                }])
                logger.info(f"RingLink: outbound {delta:+d} → Bounce")
            except Exception as e:
                logger.warning(f"RingLink: send Bounce failed, dropping {delta:+d}: {e}")
            return
        if line.startswith("CHECK_SPELL "):
            spell_name = line[len("CHECK_SPELL "):].strip()
            await self._send_named_location_check(
                kind="spell",
                game_name=spell_name,
                name_to_location=SPELL_TO_LOCATION_NAME,
            )
            return
        if line.startswith("CHECK_KEYITEM "):
            key_item_name = line[len("CHECK_KEYITEM "):].strip()
            await self._send_named_location_check(
                kind="key item",
                game_name=key_item_name,
                name_to_location=KEYITEM_TO_LOCATION_NAME,
            )
            return
        if line.startswith("CHECK_LOCID "):
            try:
                location_id = int(line[len("CHECK_LOCID "):].strip())
            except ValueError:
                logger.warning(f"Unparseable CHECK_LOCID: {line!r}")
                return
            if location_id in self.checked_locations_seen:
                return
            self.checked_locations_seen.add(location_id)
            await self._send_or_queue_ap_msg(
                {"cmd": "LocationChecks", "locations": [location_id]},
                label=f"LocationChecks for AP location id {location_id} (raw CHECK_LOCID)",
            )
            return
        if line.startswith("CHECK "):
            try:
                check_id = int(line[6:].strip())
            except ValueError:
                logger.warning(f"Unparseable CHECK: {line!r}")
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
            await self._send_or_queue_ap_msg(
                {"cmd": "LocationChecks", "locations": [location_id]},
                label=f"LocationChecks for {location_name} (id={location_id}, game CHECK {check_id})",
            )

    async def _send_named_location_check(self, kind: str, game_name: str, name_to_location: dict[str, str]) -> None:
        location_name = name_to_location.get(game_name)
        if location_name is None:
            logger.info(f"Game {kind} {game_name!r} has no AP location mapping (likely starter / non-progression); skipping")
            return
        location_id = LOCATION_NAME_TO_ID.get(location_name)
        if location_id is None:
            logger.warning(f"{kind.capitalize()} location {location_name!r} has no AP id; dropping")
            return
        if location_id in self.checked_locations_seen:
            return
        self.checked_locations_seen.add(location_id)
        await self._send_or_queue_ap_msg(
            {"cmd": "LocationChecks", "locations": [location_id]},
            label=f"LocationChecks for {location_name} (id={location_id}, {kind} {game_name!r})",
        )

    async def _send_or_queue_ap_msg(self, msg: dict, label: str) -> None:
        """Send an outbound AP message, or queue it for replay on next Connected.

        Replaces the previous "drop if AP offline" pattern that silently lost
        checks made during a server inactivity timeout or network blip. The
        mod's markers self-destroy on Touch so the location cannot be
        re-checked by re-walking-over; without this queue, every check made
        during an AP outage would be permanently lost on the AP side and the
        other player(s) waiting on that item would wait forever.
        """
        if self.server and self.slot is not None:
            try:
                await self.send_msgs([msg])
                logger.info(f"Sent {label}")
                return
            except Exception as e:
                logger.warning(f"send_msgs failed for {label}, queuing for reconnect: {e}")
        self.pending_ap_outbound.append(msg)
        logger.info(f"Queued {label} (AP offline, {len(self.pending_ap_outbound)} pending)")

    async def _flush_pending_ap_outbound(self) -> None:
        if not (self.server and self.slot is not None):
            return
        if not self.pending_ap_outbound:
            return
        msgs, self.pending_ap_outbound = self.pending_ap_outbound, []
        try:
            await self.send_msgs(msgs)
            logger.info(f"Flushed {len(msgs)} pending AP message(s) on reconnect")
        except Exception as e:
            logger.exception(f"Flush failed, re-queuing {len(msgs)} message(s): {e}")
            self.pending_ap_outbound = msgs + self.pending_ap_outbound

    def _resync_durable_grants(self) -> None:
        grants = [payload for payload in self.durable_grants if payload is not None]
        if not grants:
            logger.info("Game HELLO received; no durable grants to resync")
            return
        # Skip items already delivered earlier in this game session. Without
        # this filter, the very first HELLO of a new seed would replay each
        # item on top of the original ReceivedItems delivery (e.g. 3 starter
        # spells × 2 = 6 toasts on game start). Reset of `delivered_to_game`
        # in handle_game_connection guarantees each new game session does
        # see a full replay if it actually needs one (post-restart, save load
        # mid-session, etc.).
        to_send = [p for p in grants if f"GRANT {p}" not in self.delivered_to_game]
        if not to_send:
            logger.info(f"Game HELLO received; game is in sync ({len(grants)} grant(s) already pushed via pre-HELLO drain or inline ReceivedItems)")
            return
        skipped = len(grants) - len(to_send)
        if skipped > 0:
            logger.info(f"Game HELLO received; resyncing {len(to_send)} of {len(grants)} durable grant(s) ({skipped} already pushed since game connect)")
        else:
            logger.info(f"Game HELLO received; resyncing {len(to_send)} durable grant(s)")
        for payload in to_send:
            self._send_to_game(f"GRANT {payload}")

    def _appearance_code_for_item(self, ni) -> int:
        """Resolve a scouted NetworkItem to the mod appearance code.

        ni.player is the receiving/owner slot (LocationScouts semantics). A
        non-HP2 owner (incl. group / item-link slots) → AP-logo plate, arrow
        if the foreign item is progression or trap. An HP2 owner → that HP2
        item's own art (card 1..101 / spell 1000+idx / filler 2001..2008 /
        equipment 3001..3002 / bingo key 3003), or 0 (native) for an HP2 item
        with no mapped look.
        """
        owner = ni.player
        slot = self.slot_info.get(owner) if self.slot_info else None
        owner_game = slot.game if slot is not None else None
        if owner_game != GAME_NAME:
            if (ni.flags & 0b001) or (ni.flags & 0b100):
                return APPEARANCE_FOREIGN_ARROW
            return APPEARANCE_FOREIGN_PLAIN

        name = self.item_names.lookup_in_slot(ni.item, owner)
        if not name:
            return 0
        # Our own traps have no vanilla pickup art; show the AP-logo arrow
        # plate (same as a foreign progression/trap) so a trap-bearing chest
        # is visually flagged instead of masquerading as a real card.
        if name in TRAP_ITEM_NAMES:
            return APPEARANCE_FOREIGN_ARROW
        ucls = ITEM_NAME_TO_CARD_CLASS.get(name)
        if ucls is not None:
            return CARD_CLASS_TO_GAME_ID.get(ucls, 0)
        if name in SPELL_NAME_TO_INDEX:
            return 1000 + SPELL_NAME_TO_INDEX[name]
        if name in FILLER_CODE:
            return FILLER_CODE[name]
        if name in EQUIPMENT_CODE:
            return EQUIPMENT_CODE[name]
        if name in KEY_CODE:
            return KEY_CODE[name]
        return 0

    def _rebuild_appearance_table(self) -> None:
        """Recompute the per-location appearance payload from locations_info
        and push it to the mod if it changed. Only HP2 location ids appear in
        locations_info (we scout only our own). Codes of 0 are omitted — the
        mod clears its table on each ingest so an omitted location reverts to
        its native look."""
        pairs: list[str] = []
        for loc_id, ni in self.locations_info.items():
            try:
                code = self._appearance_code_for_item(ni)
            except Exception as e:
                logger.exception(f"appearance: failed to classify {ni!r}: {e}")
                code = 0
            if code:
                pairs.append(f"{loc_id}:{code}")
        csv = ",".join(pairs)
        if csv == self.appearance_csv:
            return
        self.appearance_csv = csv
        logger.info(f"Appearance table rebuilt: {len(pairs)} morphable location(s)")
        self._send_to_game("APPEARANCE " + csv)

    def _handle_seed_change(self, old_seed: str, new_seed: str) -> None:
        logger.info(
            f"Seed changed ({old_seed!r} → {new_seed!r}); clearing prior-seed state "
            f"({len(self.durable_grants)} durable grant(s), "
            f"{len(self.pending_grants)} pending grant(s), "
            f"{len(self.pending_ap_outbound)} pending AP msg(s), "
            f"{len(self.checked_locations_seen)} checked location(s), "
            f"goal_sent={self.goal_sent})"
        )
        self.durable_grants = []
        self.pending_grants = []
        self.pending_ap_outbound = []
        self.checked_locations_seen = set()
        self.goal_sent = False
        self.delivered_to_game = set()
        # #3: drop the prior seed's appearance table so the next Connected's
        # scout rebuilds it from scratch (item placement differs per seed).
        self.appearance_csv = None

    def _remember_durable_grant(self, payload: str, index: object) -> None:
        if isinstance(index, int) and index >= 0:
            while len(self.durable_grants) <= index:
                self.durable_grants.append(None)
            self.durable_grants[index] = payload
            return
        self.durable_grants.append(payload)

    async def run_tcp_server(self) -> None:
        server = await asyncio.start_server(
            self.handle_game_connection, GAME_TCP_HOST, GAME_TCP_PORT
        )
        sockets = ", ".join(str(s.getsockname()) for s in server.sockets)
        logger.info(f"Game-side TCP listener up on {sockets}")
        async with server:
            await server.serve_forever()


def _suppress_socket_reset(loop: asyncio.AbstractEventLoop, context: dict) -> None:
    # Windows ProactorEventLoop's _loop_reading background task can raise
    # ConnectionResetError when a socket peer disconnects abruptly (Ctrl+C
    # against the game, game window closed, etc). The error is benign but
    # surfaces as "Unhandled exception in client_connected_cb". Filter that
    # one specific case; let everything else through to the default handler.
    exc = context.get("exception")
    if isinstance(exc, (ConnectionResetError, ConnectionAbortedError)):
        return
    loop.default_exception_handler(context)


async def _main(args: argparse.Namespace) -> None:
    asyncio.get_running_loop().set_exception_handler(_suppress_socket_reset)
    ctx = HP2Context(args.connect, args.password)
    ctx.auth = args.name
    ctx.server_task = asyncio.create_task(server_loop(ctx), name="ap server loop")
    ctx.tcp_server_task = asyncio.create_task(ctx.run_tcp_server(), name="game tcp server")
    if gui_enabled:
        ctx.run_gui()
    ctx.run_cli()
    await ctx.exit_event.wait()
    await ctx.shutdown()


def launch(*launch_args: str) -> None:
    """Entry point called by the Archipelago launcher (and dev __main__)."""
    import colorama
    colorama.just_fix_windows_console()

    parser = get_base_parser(description="HP2 Archipelago client (bridge to HP2 PC mod).")
    parser.add_argument("--name", default=None, help="AP slot name to connect as.")
    parser.add_argument("url", nargs="?", help="Archipelago connection url.")
    args = parser.parse_args(launch_args)
    args = CommonClient.handle_url_arg(args, parser=parser)
    # basicConfig (not just setLevel) — without an explicit handler, INFO-level
    # logs fall through to logging's lastResort handler which drops anything
    # below WARNING. Only the warnings would surface, hiding all the useful
    # connection / item-flow chatter.
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )
    asyncio.run(_main(args))


if __name__ == "__main__":
    launch(*sys.argv[1:])
