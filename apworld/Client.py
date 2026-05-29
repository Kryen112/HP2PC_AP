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
    SAY <text>                  (game → client, ~1/100 on spell cast — cosmetic chat)
    DEATH [cause]               (game → client, Harry entered stateDead — DeathLink out)
    VENDOR_OPENED <locId>       (game → client, player opened a Tradersanity vendor dialogue → broadcast hint)
    APPLIED <index>             (game → client, item at AP index applied → mark durably consumed)
    NEWGAME                     (game → client, genuine new game (iGameState 0) → wipe ledger)
    GRANT <index> <classname>   (client → game, forward item received; index = AP ReceivedItems index)
    RINGIN <signed_int>         (client → game, net remote RingLink delta to apply)
    DEATHLINK                   (client → game, a linked player died — kill Harry)
    CONNECTED <host:port>       (client → game, AP server address for startup toast; sticky, every HELLO)
    CHECKED <id_csv>            (client → game, comma-separated AP location ids the server already has as checked; sticky, every HELLO)
    TOAST <text>                (client → game, generic cosmetic toast: DeathLink in/out, Join/Part, Goal by other slot, AP disconnect)

Durable-grant ledger: the set of applied AP indices is persisted in AP server
Data Storage (key HP2PC_AP:{team}:{slot}), loaded on Connected, written on each
APPLIED, wiped on NEWGAME. The mod's .usa cannot persist mod data (M212), so AP
storage is the source of truth for which indices have already been forwarded.

Durable AP-grant resyncs (spells, bookcase-blocker keys, potion key items): each
set of granted item names is derived live from AP's cumulative ReceivedItems
list (which the server replays in full on every Connected) and pushed to the
mod as RESYNC_SPELLS / RESYNC_BLOCKERKEYS / RESYNC_KEYITEMS on every Connected
and every game HELLO. The mod re-stamps the matching class-default flag arrays
(APGrantedSpell / APGrantedBlockerKey / APGrantedKeyItem) and restores any live
game state the .usa save dropped (spellbook entries, bookcase blocker actors,
Harry's ingredient StatusItems), so a process restart that wiped the compiled
class-defaults can never strand the slot — the consumed-indices ledger would
otherwise block any GRANT replay for these items.

AP-side protocol: standard Archipelago WebSocket (handled by CommonContext).
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import random
import sys
import time
import urllib.parse
import warnings
from typing import Optional

# Silence the upstream setuptools deprecation that fires every time AP imports
# pkg_resources (Archipelago/ModuleUpdate.py:76). Must run before importing
# CommonClient below so the filter is in place when the warning would emit.
warnings.filterwarnings("ignore", message=".*pkg_resources is deprecated.*")

import CommonClient
from CommonClient import (ClientCommandProcessor, CommonContext,
                          get_base_parser, gui_enabled, server_loop)
from NetUtils import ClientStatus, SlotType

from . import HP2World, sound_patch
from .items import CARD_CLASS_TO_ITEM_NAME, FILLER_NAMES, ITEM_GROUPS
from .locations import (CARD_CLASS_TO_LOCATION_NAME,
                        CARD_GAME_ID_TO_LOCATION_NAME, LOCATION_GROUPS,
                        LOCATION_NAME_TO_ID)

ITEM_NAME_TO_CARD_CLASS = {item_name: ucls for ucls, item_name in CARD_CLASS_TO_ITEM_NAME.items()}


def _hp2_install_path(open_castle: bool) -> Optional[str]:
    """Configured install folder for the seed's game mode (open castle vs
    vanilla), or None. Read at call time so a host.yaml edit needs no client
    change. An unset folder is filtered by the caller's HPSounds.u existence check."""
    field = "open_castle_install_folder" if open_castle else "vanilla_install_folder"
    try:
        path = str(getattr(HP2World.settings, field)).strip()
    except Exception:
        return None
    return path or None
# All wizard-card item names, derived from ITEM_GROUPS so it can never drift
# from data/items.yaml. Used by /progress to count cards in received items.
CARD_ITEM_NAMES_SET = frozenset(
    ITEM_GROUPS.get("Cards (Bronze)", [])
    + ITEM_GROUPS.get("Cards (Silver)", [])
    + ITEM_GROUPS.get("Cards (Gold)", [])
)
# Base AP id for the 12 level-completion locations (Hogwarts/Boomslang/...,
# Aragog, Basilisk, the 4 spell challenges, Whomping Willow, Slytherin,
# Gryffindor challenge). idx 0..11 = AP id - LEVEL_COMPLETION_BASE.
LEVEL_COMPLETION_BASE = 5760700
LEVEL_COMPLETION_COUNT = 12
# Trap item names, from ITEM_GROUPS so it can never drift from
# data/items.yaml. Used by the #3 marker-appearance classifier. Every
# received item is gated by the AP-Data-Storage consumed-index ledger (see
# _forward_one / consumed_indices), so filler and traps are durable-but-once
# exactly like cards/spells, with no special-casing.
TRAP_ITEM_NAMES = frozenset(ITEM_GROUPS.get("Traps", []))

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

# DeathLink race-insurance amnesty. An inbound death within this window
# of the last death in either direction (CommonContext.last_death_link, stamped
# by send_death and on_deathlink) is treated as simultaneity and not bounced
# into the game; an outbound DEATH within it is not re-broadcast. The
# deterministic loop is handled mod-side by the suppression latch — this only
# mops up genuine within-a-round-trip races.
DEATHLINK_AMNESTY_S = 2.0

# Map UScript spell name (as fired by APCardWatcher's CHECK_SPELL) to the
# AP location it represents. Only the 4 non-starter spells have classroom
# locations and so live in this map — each is taught after its classroom's
# spell challenge. Story order: Rictusempra (Lockhart#1) → Skurge (Flitwick)
# → Diffindo (Sprout) → Spongify (Lockhart#2). Lumos/Flipendo/Alohomora have
# no classroom location; harry.uc:335-337 adds them to every fresh Harry, the
# mod's Snapshot+revert wipes them unless AP has granted them, and the AP
# grant restores them. Whether they're starters depends on `starting_spells`.
# See data/locations.yaml.
SPELL_TO_LOCATION_NAME = {
    "Rictusempra": "Learned Rictusempra",
    "Skurge":      "Learned Skurge",
    "Diffindo":    "Learned Diffindo",
    "Spongify":    "Learned Spongify",
}

# Spell-cast chat flavor: the mod fires a bare ASCII spell name over SAY on a
# rate-limited ~1/100 roll; the client builds the chat line (see
# _build_spell_flavor).

# Map UScript special progression name to its AP check. Empty: Boomslang,
# Bicorn, and BitOGoyle are not randomized, they flow through vanilla story.
# The watcher still fires CHECK_KEYITEM when it sees a vanilla pickup; the
# client's _send_named_location_check then logs "no AP location mapping" and
# silently skips. Add entries when these become AP checks.
KEYITEM_TO_LOCATION_NAME: dict[str, str] = {}

# Marker appearance. The client scouts every HP2 location, resolves what item
# each holds, and pushes a per-location appearance code the mod uses to morph
# the marker into that item's vanilla art. Codes mirror
# APCardWatcher.AppearanceCode[].

# Spell appearance index — MUST match APCardWatcher.SpellNames[] order
# (0 Alohomora … 6 Spongify). Appearance code = 1000 + index.
SPELL_NAME_TO_INDEX = {
    "Alohomora": 0, "Diffindo": 1, "Flipendo": 2, "Lumos": 3,
    "Rictusempra": 4, "Skurge": 5, "Spongify": 6,
}

# The 7 AP item names treated as spells. Used by `granted_spell_names` to
# filter the cumulative received-items dict into a spell-only set for the
# RESYNC_SPELLS payload. Same set as ITEM_GROUPS['Spells'] but reads as a
# frozenset for membership tests.
SPELL_ITEM_NAMES_SET = frozenset(SPELL_NAME_TO_INDEX)

# AP item names treated as bookcase-blocker keys (the 14 region keys, used in
# both modes); same set as ITEM_GROUPS['Blocker Keys']. Used by
# `granted_blocker_key_names` to filter received_by_index for the
# RESYNC_BLOCKERKEYS payload.
BLOCKER_KEY_NAMES_SET = frozenset(ITEM_GROUPS['Blocker Keys'])

# AP item names treated as potion-ingredient key items. Not in items.yaml today
# (KEYITEM_TO_LOCATION_NAME is empty too), but the mod's TryApplyKeyItem already
# accepts these exact strings as GRANT payloads, so the resync is wired up in
# lockstep with spells / blocker keys: future randomization of any of these
# three inherits save-load survivability with zero extra wiring.
KEY_ITEM_NAMES_SET = frozenset(['Boomslang', 'Bicorn', 'BitOGoyle'])

# Filler appearance code — FILLER_NAMES order maps 1:1 to the mod's 2001..2008
# (Small/Medium/Large/Massive Beans, Wiggenweld, Wiggentree Bark, Flobberworm,
# Chocolate Frog).
FILLER_CODE = {name: 2001 + i for i, name in enumerate(FILLER_NAMES)}

# Equipment appearance code — vanilla HProp pickups morphed to their own
# vanilla mesh, same as cards/spells/filler (mod codes 3001..3002).
EQUIPMENT_CODE = {'Nimbus 2001': 3001, 'Quidditch Armour': 3002}

# Bookcase-blocker key appearance code — the 14 region keys all share the
# vanilla "silver key" FX sprite (mod code 3003). Sourced from the canonical
# ITEM_GROUPS entry so the set never drifts from items.yaml.
KEY_CODE = {name: 3003 for name in ITEM_GROUPS['Blocker Keys']}

# Foreign (non-HP2) item codes — the only surviving #1 contribution: the
# AP-logo plate, arrow variant when the foreign item is progression or trap
# (progression_skip_balancing collapses to the progression bit), plain
# otherwise. This is the sole place the classification arrow is computed.
APPEARANCE_FOREIGN_PLAIN = 9000
APPEARANCE_FOREIGN_ARROW = 9001

logger = logging.getLogger("HP2Client")


def _log_safe(text: str, limit: int = 180) -> str:
    """Truncate a payload for logging only. The AP Kivy client renders every
    INFO line into an on-screen log widget; a single multi-KB line (the
    APPEARANCE table is ~6.5 KB) stalls Kivy's text layout and hangs the
    asyncio event loop for over a minute. The full text is still sent to the
    game unchanged; this shortens only what is written to the log."""
    if len(text) <= limit:
        return text
    return f"{text[:limit]}… [+{len(text) - limit} more chars]"


class HP2CommandProcessor(ClientCommandProcessor):
    def _cmd_restore_sounds(self) -> bool:
        """Restore the original SFX: copy HPSounds.u.orig back over HPSounds.u for
        every configured install, without connecting to a seed. Takes effect on
        the next game launch."""
        installs = []
        for mode, open_castle in (("vanilla", False), ("open castle", True)):
            path = _hp2_install_path(open_castle)
            if path and os.path.exists(sound_patch.package_path(path)):
                installs.append((mode, path))
        if not installs:
            self.output("No install with system/HPSounds.u is configured. Set "
                        "'harry_potter_2_pc_options' -> vanilla_install_folder / "
                        "open_castle_install_folder in host.yaml.")
            return True
        for mode, path in installs:
            try:
                result = sound_patch.restore_original(path)
            except (sound_patch.PatchError, OSError) as exc:
                self.output(f"{mode}: restore failed: {exc}")
                continue
            if result == "restored":
                self.output(f"{mode}: original sounds restored. Restart Harry Potter if it is running.")
            elif result == "unchanged":
                self.output(f"{mode}: already original.")
            else:
                self.output(f"{mode}: no HPSounds.u.orig backup found; nothing to restore.")
        return True

    def _cmd_progress(self) -> bool:
        """Show progress toward the open castle goal: cards / spells / level
        objectives / duels / quidditch matches against the thresholds the seed
        was rolled with."""
        ctx: "HP2Context" = self.ctx
        if not ctx.is_open_castle:
            self.output(
                "/progress is for open castle seeds. Vanilla seeds win on the "
                "post-Basilisk credits, not on threshold counts."
            )
            return True
        if ctx.open_castle_goalcfg is None:
            self.output("Goal config not received yet (waiting on slot_data from AP).")
            return True
        parts = ctx.open_castle_goalcfg.split(",")
        if len(parts) < 6:
            self.output(f"Goal config malformed: {ctx.open_castle_goalcfg!r}")
            return True
        cards_need, spells_need, levels_need, duels_need, quid_need, level_mask = (
            int(x) for x in parts
        )

        cards_have = 0
        for item in ctx.received_by_index.values():
            name = ctx.item_names.lookup_in_game(item.item, GAME_NAME)
            if name in CARD_ITEM_NAMES_SET:
                cards_have += 1
        spells_have = len(ctx.granted_spell_names)

        checked = ctx.checked_locations
        levels_have = sum(
            1 for loc_id in checked
            if LEVEL_COMPLETION_BASE <= loc_id < LEVEL_COMPLETION_BASE + LEVEL_COMPLETION_COUNT
            and (level_mask >> (loc_id - LEVEL_COMPLETION_BASE)) & 1
        )
        duels_have = 0
        quid_have = 0
        for loc_id in checked:
            name = ctx.location_names.lookup_in_game(loc_id, GAME_NAME)
            group = LOCATION_GROUPS.get(name, "")
            if group == "Duels":
                duels_have += 1
            elif group == "QuidditchMatches":
                quid_have += 1

        def row(label: str, have: int, need: int) -> str:
            tick = "[x]" if have >= need else "[ ]"
            return f"  {tick} {label:<22} {have} / {need}"

        self.output("Open castle goal progress:")
        self.output(row("Wizard cards",          cards_have,  cards_need))
        self.output(row("Spells",                spells_have, spells_need))
        self.output(row("Level objectives",      levels_have, levels_need))
        self.output(row("Duels won",             duels_have,  duels_need))
        self.output(row("Quidditch matches won", quid_have,   quid_need))
        return True


class HP2Context(CommonContext):
    game = GAME_NAME
    command_processor = HP2CommandProcessor
    items_handling = 0b111  # receive starting inventory + own items + remote items
    want_slot_data = True  # open castle Great Hall key thresholds ride slot_data

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
        # Outbound AP messages queued while the AP server is offline. Drained
        # on every successful Connected. In-memory only — a client crash
        # during an AP outage loses these.
        self.pending_ap_outbound: list[dict] = []
        # --- Durable-grant ledger ------------------------------------------
        # The single source of truth for "which AP items has this slot's
        # playthrough already had applied" is an Archipelago server-side Data
        # Storage record (NOT the M212 .usa, which cannot persist mod data).
        # consumed_indices = the set of absolute AP ReceivedItems indices the
        # mod has confirmed-applied (via the APPLIED ack). It is loaded from AP
        # storage on Connected and written back on every APPLIED. On (re)connect
        # / HELLO the client replays every received item whose index is NOT in
        # the set; an item already in the set is never re-sent → no double
        # bean / re-fired trap / phantom inventory. ledger_key is
        # HP2PC_AP:{team}:{slot} (the store is per-seed by virtue of being on
        # that seed's server, so seed need not be in the key).
        self.ledger_key: Optional[str] = None
        self.consumed_indices: set[int] = set()
        # Held until the AP-storage Get resolves so replay can't run against an
        # unknown ledger and double-grant.
        self.ledger_loaded: bool = False
        # Every (abs_index → NetworkItem) seen on the current AP connection, so
        # HELLO / post-load / post-NEWGAME can re-evaluate and forward the ones
        # not yet consumed. Idempotent across AP resyncs (keyed by index).
        self.received_by_index: dict[int, object] = {}
        # Per-game-session set of AP indices already written to the game writer
        # (immediate or via the offline-queue drain). Reset on every new game
        # connect (handle_game_connection). Prevents the HELLO re-forward and
        # the pending-grants drain from double-sending the same index before
        # its APPLIED ack lands.
        self.sent_this_session: set[int] = set()
        # --- Durable spell-grant ledger ------------------------------------
        # The set of spell item names this slot has ever received from AP is
        # NOT a separate Data Storage record — it is derived live from
        # received_by_index by the `granted_spell_names` property. AP's
        # cumulative ReceivedItems replay on every Connected is the source of
        # truth, so an already-consumed spell index (never re-forwarded as a
        # GRANT) still re-asserts as `RESYNC_SPELLS` on every connect/HELLO
        # via the property — covering the .usa save-load that dropped the
        # SpellBook[] class ref and the cold mod-process boot that reset
        # default.APGrantedSpell[].
        # Last seed_name observed via RoomInfo. On change, wipe seed-specific
        # state in _handle_seed_change so a long-running client targeting the
        # same host:port across seeds doesn't replay seed A's items to seed B.
        # CommonContext.reset_server_state is NOT the right hook — it runs on
        # every disconnect, including transient AP blips, which the durable
        # ledger must survive.
        self._last_seed_name: Optional[str] = None
        # Open castle Great Hall key config as the "GOALCFG c,s,l,d,q,mask"
        # payload, or None for vanilla / not-yet-received. Parsed from slot_data
        # on Connected; pushed to the mod on every game HELLO (sticky +
        # idempotent mod-side, so a fresh game launch / reconnect re-arms it).
        self.open_castle_goalcfg: Optional[str] = None
        # Tradersanity price mode as the "TRADECFG <int>" payload (0 off /
        # 1 vanilla / 2 random / 3 low), or None if not yet received. Parsed
        # from slot_data on Connected; pushed every game HELLO (sticky +
        # idempotent mod-side), same lifecycle as open_castle_goalcfg.
        self.tradersanity_cfg: Optional[str] = None
        # Tradersanity per-vendor rolled price factors as the
        # "TRADERPRICES locId:factor,..." payload, or None if not received /
        # tradersanity is off. Parsed from slot_data on Connected (apworld
        # pre-rolled the factors from its seeded RNG); pushed every HELLO so
        # the per-seed prices survive game launches and reconnects.
        self.tradersanity_prices_csv: Optional[str] = None
        # When true, the first VENDOR_OPENED IPC observed for each Tradersanity
        # location publishes a broadcast hint (LocationScouts create_as_hint=2).
        # Parsed from slot_data on Connected.
        self.tradersanity_hint_on_open: bool = False
        # When true, the mod silences every vendor's in-trade voice cues
        # (sell / out-of-stock / transaction-done / decline / etc.) by zeroing
        # their VendorDialog string ids so VendorManager.DoCutTalk hits its
        # empty-dialog fast path. Parsed from slot_data on Connected, sent
        # SKIP_VENDOR_VOICES <0|1> to the mod on every HELLO so a reconnect
        # or fresh game launch re-asserts the state.
        self.skip_vendor_voices: bool = False
        # When true, Fred (Nimbus 2001) and George (Quidditch Armour) sell
        # AP-tracked items, so the mod paints them with the Tradersanity
        # icon / banner / hint. Parsed from slot_data on Connected, re-sent
        # QUIDDITCH_UPGRADES <0|1> on every HELLO.
        self.quidditch_upgrades: bool = False
        # Per-seed sticky set of Tradersanity location ids the client has
        # already published a broadcast hint for, loaded from AP server Data
        # Storage on Connected and written back on each new hint so a
        # reconnect / client restart never re-broadcasts the same hint.
        self.vendor_hint_key: Optional[str] = None
        self.hinted_vendor_locs: set[int] = set()
        # Music randomizer config. Parsed from slot_data on Connected; pushed
        # every HELLO so a fresh game launch / reconnect re-asserts the pools
        # mod-side. Sticky + idempotent mod-side. All three are None / False
        # for vanilla seeds (option off → apworld suppresses the slot_data
        # keys entirely). The pools are CSV strings (no commas in any
        # basename) rather than separate IPC lines per entry — single sticky
        # snapshot is simpler to re-arm.
        self.music_randomizer_enabled: bool = False
        self.music_pool_csv: Optional[str] = None
        self.jingle_pool_csv: Optional[str] = None
        self.music_seed: Optional[int] = None
        # Sound randomizer. Unlike music this is not an IPC signal to the mod:
        # on Connected the client binary-patches the local HPSounds.u (per
        # sound_pool.py + sound_seed) and the game loads it on next launch. Off
        # seeds omit both keys (apworld suppresses them) and restore the backup.
        self.sound_randomizer_enabled: bool = False
        self.sound_seed: Optional[int] = None
        # True when slot_data game_mode == "open_castle". Drives the one-way
        # "MODE open_castle" IPC line (sticky + idempotent mod-side; resent
        # every game HELLO) — a durable, authoritative open castle signal that
        # survives a cold load into a sentinel-less level. The open-castle flag
        # itself (bOpenCastleMode) is one-way sticky and never cleared.
        self.is_open_castle: bool = False
        # The seed's declared game_mode ("vanilla" / "open_castle"), or None
        # until Connected. Sent verbatim as the "MODE <mode>" IPC line on
        # Connected and re-armed every game HELLO. Unlike is_open_castle this is
        # a POSITIVE signal in both modes: the mod compares it against its own
        # install probe (the MGBingo package) to warn when a seed is played on
        # the wrong maps. "MODE open_castle" additionally latches bOpenCastleMode
        # mod-side; "MODE vanilla" only records the declared mode (never clears
        # bOpenCastleMode — that invariant is preserved).
        self.seed_mode: Optional[str] = None
        # #3: last "apId:code,…" appearance payload pushed to the mod, or None
        # if not yet built. Resent on every game HELLO (sticky + idempotent
        # mod-side). Rebuilt from self.locations_info on each LocationInfo.
        self.appearance_csv: Optional[str] = None
        # RingLink. Enabled per-slot via slot_data on Connected. ring_source
        # is a per-connection random int UUID, re-rolled every Connected, used
        # as the Bounce `source` field and as the self-filter key so the
        # server's echo of our own Bounce is dropped. Replaces a slot-name key
        # so co-op-on-one-slot links and SA2/SMW interop both work.
        self.ring_link_enabled: bool = False
        self.ring_source: Optional[int] = None
        # DeathLink. Opt-in per-slot via slot_data on Connected; the tag
        # itself lives on self.tags (managed by update_death_link). Inbound
        # deaths are NOT queued for an offline game — you can't die when not
        # playing, so a death received then is stale and dropped. Loop
        # prevention is the deterministic mod-side suppression latch; this
        # timestamp amnesty is only race insurance for genuine simultaneity
        # (CommonContext.last_death_link is stamped by both send_death and
        # on_deathlink, so it tracks the last death in either direction).
        self.death_link_enabled: bool = False
        # Startup "Connected to host:port" toast. The effective AP server
        # address (scheme stripped, port defaulted), formatted on every
        # Connected from self.server_address — which server_loop has by then
        # normalised to ws://host[:port]. Pushed as the sticky CONNECTED IPC
        # line now if the game is up, else on the next game HELLO. Sticky +
        # idempotent mod-side (same lifecycle as open_castle_goalcfg); the mod
        # owns the once-per-launch / once-per-save-load fire latch, so resending
        # the same address on a reconnect / HELLO never re-toasts.
        self.connected_address: Optional[str] = None
        # CHECKED resync. AP server's per-slot checked_locations rebuilt into
        # a comma-separated AP-location-id string, pushed every game HELLO so
        # the mod can stamp class-default LocationChecked[] /
        # NonCardLocationChecked[] arrays on a fresh process. The mod's arrays
        # are process-lifetime only (class-defaults are compiled, never read
        # from the .usa), so the AP server is the source of truth across game
        # close+reload. None until the first rebuild from Connected /
        # RoomUpdate; empty string is a valid payload (no checks yet, still
        # resent every HELLO to overwrite any stale stamp on a reconnect).
        self.checked_csv: Optional[str] = None

    @staticmethod
    def _format_ap_address(raw: Optional[str]) -> Optional[str]:
        """`host:port` for the toast, or None. Mirrors server_loop: prefix
        ws:// if schemeless so urlparse populates host/port, drop any
        user:pass@ credentials, and default the port to 38281 exactly as
        websockets.connect does (server_url.port or 38281)."""
        if not raw:
            return None
        addr = raw if "://" in raw else f"ws://{raw}"
        try:
            u = urllib.parse.urlparse(addr)
            host = u.hostname
            port = u.port or 38281
        except ValueError:
            return None
        if not host:
            return None
        return f"{host}:{port}"

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

            # Durable-grant ledger: (re)fetch this slot's consumed-index set
            # from AP server Data Storage. Hold replay until the Retrieved
            # response lands (handled in on_package below) so we never replay
            # against an unknown ledger. received_by_index is rebuilt from the
            # fresh ReceivedItems AP resends on this connection.
            self.ledger_key = f"HP2PC_AP:{self.team}:{self.slot}"
            self.ledger_loaded = False
            self.received_by_index = {}
            asyncio.create_task(self._send_or_queue_ap_msg(
                {"cmd": "Get", "keys": [self.ledger_key]},
                label=f"Get durable ledger {self.ledger_key}",
            ))

            # Startup connection toast. server_loop has set self.server_address
            # to the normalised ws://host[:port] it actually connected to by
            # the time Connected is processed. Push now if the game is up;
            # otherwise it rides the next game HELLO. Sticky + idempotent
            # mod-side; recomputed every Connected so a reconnect stays
            # correct (the mod's latch keeps it from re-toasting).
            self.connected_address = self._format_ap_address(self.server_address)
            if self.connected_address and self.game_writer is not None:
                self._send_to_game("CONNECTED " + self.connected_address)
            sd = args.get("slot_data") or {}
            self.is_open_castle = sd.get("game_mode") == "open_castle"
            self.seed_mode = "open_castle" if self.is_open_castle else "vanilla"
            if self.game_writer is not None:
                self._send_to_game("MODE " + self.seed_mode)
            if sd.get("game_mode") == "open_castle":
                self.open_castle_goalcfg = "{},{},{},{},{},{}".format(
                    sd.get("open_castle_goal_cards", 0),
                    sd.get("open_castle_goal_spells", 0),
                    sd.get("open_castle_goal_levels", 0),
                    sd.get("open_castle_goal_duels", 0),
                    sd.get("open_castle_goal_quidditch", 0),
                    sd.get("open_castle_level_mask", 0),
                )
                logger.info(f"Open castle goal config from slot_data: {self.open_castle_goalcfg}")
                # If the game is already connected, push now; otherwise it goes
                # out on the next game HELLO.
                if self.game_writer is not None:
                    self._send_to_game("GOALCFG " + self.open_castle_goalcfg)
            else:
                self.open_castle_goalcfg = None

            # Tradersanity price mode (both game modes; slot_data carries it
            # for vanilla and open castle). Sticky like open_castle_goalcfg:
            # push now if the game is up, else it rides the next HELLO.
            # Default 0 (off).
            self.tradersanity_cfg = str(int(sd.get("tradersanity", 0)))
            logger.info(f"Tradersanity mode from slot_data: {self.tradersanity_cfg}")
            if self.game_writer is not None:
                self._send_to_game("TRADECFG " + self.tradersanity_cfg)

            # Tradersanity per-vendor price factors (byte 0..255 per
            # Tradersanity location id), pre-rolled in the apworld from the
            # seeded RNG. Mod blends each factor into [LO,HI] for
            # price_random, or the vendor's own [min,max] for price_vanilla
            # on a card vendor, so a vendor's AP-check price is fixed for
            # the seed across level transitions AND save/exit. Same sticky
            # lifecycle as tradersanity_cfg. Empty / missing → suppress the
            # IPC line; mod side falls back to its built-in RandRange.
            factors = sd.get("tradersanity_prices") or []
            if factors:
                self.tradersanity_prices_csv = ",".join(
                    f"{int(loc_id)}:{int(factor)}" for loc_id, factor in factors
                )
                logger.info(
                    f"Tradersanity per-vendor price factors from slot_data: "
                    f"{len(factors)} entries"
                )
                if self.game_writer is not None:
                    self._send_to_game("TRADERPRICES " + self.tradersanity_prices_csv)
            else:
                self.tradersanity_prices_csv = None

            # Hint-on-open for Tradersanity vendors. (Re)fetch the per-seed
            # sticky set so a reconnect or client restart never re-broadcasts
            # the same hint. Disabled (and the set left empty) when off, so a
            # later VENDOR_OPENED is a cheap no-op.
            self.tradersanity_hint_on_open = bool(sd.get("tradersanity_hint_on_open"))
            self.skip_vendor_voices = bool(sd.get("skip_vendor_voices"))
            self._send_to_game(f"SKIP_VENDOR_VOICES {1 if self.skip_vendor_voices else 0}")
            logger.info(f"Skip vendor voices {'enabled' if self.skip_vendor_voices else 'disabled'}")
            self.quidditch_upgrades = bool(sd.get("enable_quidditch_upgrades"))
            self._send_to_game(f"QUIDDITCH_UPGRADES {1 if self.quidditch_upgrades else 0}")
            logger.info(f"Quidditch upgrades {'enabled' if self.quidditch_upgrades else 'disabled'}")
            self.vendor_hint_key = f"HP2PC_AP:vendor_hints:{self.team}:{self.slot}"
            self.hinted_vendor_locs = set()
            if self.tradersanity_hint_on_open:
                asyncio.create_task(self._send_or_queue_ap_msg(
                    {"cmd": "Get", "keys": [self.vendor_hint_key]},
                    label=f"Get vendor-hint set {self.vendor_hint_key}",
                ))
            logger.info(
                f"Tradersanity hint-on-open {'enabled' if self.tradersanity_hint_on_open else 'disabled'}"
            )

            # Music randomizer pools. Suppressed apworld-side when off, so
            # absent keys collapse the mod-side IPC vars back to disabled.
            # When on, both pools are pushed as CSVs and the enabled flag
            # rides its own line so the mod can latch behavior even if
            # parsing one of the larger payloads is in flight.
            if bool(sd.get("music_randomizer")):
                self.music_randomizer_enabled = True
                self.music_pool_csv = ",".join(sd.get("music_pool") or [])
                self.jingle_pool_csv = ",".join(sd.get("jingle_pool") or [])
                self.music_seed = int(sd.get("music_seed") or 0)
                logger.info(
                    f"Music randomizer enabled from slot_data: "
                    f"{len(sd.get('music_pool') or [])} music / "
                    f"{len(sd.get('jingle_pool') or [])} jingle tracks, "
                    f"seed={self.music_seed}"
                )
                if self.game_writer is not None:
                    self._send_to_game("MUSICRAND 1")
                    self._send_to_game(f"MUSICSEED {self.music_seed}")
                    self._send_to_game("MUSICPOOL " + self.music_pool_csv)
                    self._send_to_game("JINGLEPOOL " + self.jingle_pool_csv)
            else:
                self.music_randomizer_enabled = False
                self.music_pool_csv = None
                self.jingle_pool_csv = None
                self.music_seed = None
                if self.game_writer is not None:
                    self._send_to_game("MUSICRAND 0")

            # Sound randomizer. Patches the local HPSounds.u rather than
            # signalling the mod; runs off the event loop since it rewrites a
            # large file. Off seeds restore the .orig backup.
            asyncio.create_task(self._sync_sound_randomizer(sd))

            # RingLink. Re-roll the per-connection source UUID and
            # (re)register the tag on every Connected so a reconnect stays
            # routable for Bounced packets. Disable cleanly if a later seed
            # / reconnect turns it off.
            if sd.get("ring_link"):
                asyncio.create_task(self._enable_ring_link())
            else:
                asyncio.create_task(self._disable_ring_link())

            # DeathLink. Opt-in via slot_data. update_death_link
            # (CommonClient.py) mutates self.tags then ConnectUpdate, so the
            # tag persists across a reconnect's Connect; re-run on every
            # Connected so a seed change / reconnect re-asserts the right
            # state. Built-in dispatch (process_server_cmd) calls
            # on_deathlink for inbound DeathLink Bounces once tagged.
            self.death_link_enabled = bool(sd.get("death_link"))
            asyncio.create_task(self.update_death_link(self.death_link_enabled))
            logger.info(f"DeathLink {'enabled' if self.death_link_enabled else 'disabled'} for this slot")

            # #3: scout this slot's HP2 locations so the appearance table can
            # resolve what item each marker holds. create_as_hint=0 → peek
            # only, no hint broadcast (no spoiler-policy issue).
            #
            # MUST intersect with server_locations: LOCATION_NAME_TO_ID is the
            # full cross-mode/all-options universe, but an open castle /
            # option-trimmed seed only instantiates a subset for this slot. Scouting a
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

            # CHECKED resync. server_locations + checked_locations are
            # populated by CommonContext before on_package runs for Connected,
            # so the first rebuild here gives us a full payload. RoomUpdate
            # below rebuilds incrementally as co-op partners collect.
            self._rebuild_checked_csv()
        elif cmd == "RoomUpdate":
            # The server pushes a checked_locations delta whenever any client
            # (including ours via a different process) collects one of our
            # locations. CommonContext has already merged the delta into
            # self.checked_locations by the time on_package runs, so just
            # rebuild from scratch — the diff against self.checked_csv
            # suppresses no-op pushes.
            if "checked_locations" in args:
                self._rebuild_checked_csv()
        elif cmd == "ReceivedItems":
            base = args.get("index") or 0
            for offset, item in enumerate(args.get("items", [])):
                # Absolute index in this slot's cumulative ReceivedItems list —
                # the stable per-item key used by the durable ledger. AP resends
                # the full list (base 0) on every reconnect, so storing by index
                # is idempotent.
                idx = base + offset
                self.received_by_index[idx] = item
                # Only forward once the ledger is known; otherwise replay could
                # run against an unknown consumed-set and double-grant. The
                # Retrieved handler does the catch-up forward.
                if self.ledger_loaded:
                    self._forward_one(idx, item)
        elif cmd == "Retrieved":
            keys = args.get("keys") or {}
            if self.vendor_hint_key is not None and self.vendor_hint_key in keys:
                val = keys.get(self.vendor_hint_key)
                self.hinted_vendor_locs = set(int(x) for x in val) if val else set()
                logger.info(
                    f"Tradersanity vendor-hint set loaded: "
                    f"{len(self.hinted_vendor_locs)} already-hinted location(s)"
                )
            if self.ledger_key is not None and self.ledger_key in keys:
                val = keys.get(self.ledger_key)
                self.consumed_indices = set(val) if val else set()
                self.ledger_loaded = True
                logger.info(
                    f"Durable ledger loaded: {len(self.consumed_indices)} "
                    f"consumed index(es) for {self.ledger_key}"
                )
                # Drain queued GRANTs (items not yet consumed) BEFORE the
                # RESYNC. AP's ReceivedItems for this connection has already
                # arrived (server sends it immediately after Connected, before
                # processing our Get reply), so received_by_index is fully
                # populated and granted_spell_names reflects every spell this
                # slot has ever received. RESYNC opens the mod's wipe gate; the
                # gate keeps existing F/L/A in place for spells the property
                # includes, and correctly wipes any in-book spell the slot has
                # never received from AP.
                self._forward_all_received()
                self._send_resync_spells()
                self._send_resync_blocker_keys()
                self._send_resync_key_items()
        elif cmd == "LocationInfo":
            # CommonContext's built-in handler has already populated
            # self.locations_info[loc] = NetworkItem for every scouted
            # location before on_package runs. Rebuild + push the table.
            self._rebuild_appearance_table()
            # Vendor hints: when hint-on-open is on, push the resolved item
            # name for each Tradersanity location to the mod so the in-trade
            # label reads the actual item, not the generic "Archipelago Item".
            self._send_vendor_hints_to_mod()
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

    def on_deathlink(self, data: dict) -> None:
        """Inbound DeathLink: a linked player died → tell the mod to kill
        Harry. Dispatched synchronously by CommonClient.process_server_cmd,
        which already drops our own echo (last_death_link != data['time']).
        Amnesty is read before super() stamps last_death_link so it reflects
        our prior death activity, not this event. Not queued when the game is
        offline: a death received while not playing is stale (you can't die),
        and replaying it on reconnect would kill a freshly-loaded Harry."""
        amnesty = (time.time() - self.last_death_link) < DEATHLINK_AMNESTY_S
        super().on_deathlink(data)
        if not self.death_link_enabled:
            return
        if amnesty:
            logger.info("DeathLink: inbound within amnesty window — not forwarding")
            return
        if self.game_writer is None or self.game_writer.is_closing():
            logger.info("DeathLink: inbound dropped (game offline; stale when not playing)")
            return
        try:
            self.game_writer.write(b"DEATHLINK\n")
            logger.info(f"DeathLink: inbound from {data.get('source', '?')} → DEATHLINK")
            # Cosmetic toast. cause is the flavour string the sender chose
            # (e.g. "Harry got avada kadavra'd") and is preferred over the
            # bare source name when present. Drop-on-offline path. The
            # game-offline case already returned above.
            cause = data.get("cause") or ""
            source = data.get("source") or "?"
            self._toast_to_game(cause if cause else f"DeathLink received from {source}")
        except Exception as e:
            logger.warning(f"DeathLink: failed to forward inbound, dropping: {e}")

    def on_print_json(self, args: dict) -> None:
        # Toast feedback for items WE send to other slots ("Sent X to Y").
        # AP server broadcasts an ItemSend PrintJSON for every cross-slot
        # delivery; we filter to ones where item.player == self.slot (we're
        # the sender). Skip if receiving == self.slot — that's our own item
        # and ReceivedItems already triggers a "Received X from Y" toast,
        # so a SENT toast on top would be a duplicate.
        try:
            ptype = args.get("type")
            if ptype == "ItemSend":
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
            elif ptype in ("Join", "Part", "Goal"):
                # Other-slot lifecycle events. Filter to our own team and skip
                # our own slot (own Join fires on every reconnect. Our Goal is
                # already acked locally via GOAL_COMPLETE). slot 0 is the
                # server pseudo-slot which never fires these, but the
                # defensive check is cheap.
                slot = args.get("slot")
                team = args.get("team")
                if (
                    slot is not None
                    and slot != self.slot
                    and slot != 0
                    and (team is None or team == self.team)
                ):
                    name = self.player_names.get(slot, f"player_{slot}")
                    if ptype == "Join":
                        self._toast_to_game(f"{name} joined")
                    elif ptype == "Part":
                        self._toast_to_game(f"{name} left")
                    else:
                        self._toast_to_game(f"{name} finished!")
        except Exception as e:
            logger.exception(f"on_print_json: failed to handle {args.get('type')!r}: {e}")
        super().on_print_json(args)

    async def connection_closed(self) -> None:
        """Toast on AP websocket close. Mirrors the existing "Connected to
        host:port" toast lifecycle (CommonContext calls this on every clean /
        unclean server-side close). Must be async and await super(): the base
        method is a coroutine, and it is what runs reset_server_state (clears
        self.server). A sync override would never run it, so the GUI's
        Disconnect button and title bar stay stuck on the connected state.
        super() resets server state, so the toast is gated on slot-known to
        suppress a never-authed first-launch close (wrong password, bad
        address) from toasting spuriously."""
        was_authed = self.slot is not None
        await super().connection_closed()
        if was_authed:
            self._toast_to_game("Disconnected from AP server")

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

    async def _disable_ring_link(self) -> None:
        # Clean teardown mirroring update_death_link(False): drop the RingLink
        # tag + ConnectUpdate so the server stops routing RingLink Bounces to a
        # slot that no longer honours them (we'd ignore them anyway, but
        # advertising a dead tag is wasteful and asymmetric with DeathLink).
        # No-op when never tagged (the common ring_link-off case).
        was_enabled = self.ring_link_enabled
        self.ring_link_enabled = False
        self.ring_source = None
        if "RingLink" not in self.tags:
            return
        self.tags = set(self.tags) - {"RingLink"}
        if self.server and not self.server.socket.closed:
            try:
                await self.send_msgs([{"cmd": "ConnectUpdate", "tags": self.tags}])
            except Exception as e:
                logger.exception(f"RingLink: ConnectUpdate(tags) untag failed: {e}")
                return
        if was_enabled:
            logger.info("RingLink disabled for this slot; RingLink tag removed")

    def _send_to_game(self, text: str) -> None:
        if self.game_writer is None or self.game_writer.is_closing():
            self.pending_grants.append(text)
            logger.info(f"Queued (no game connection yet, {len(self.pending_grants)} pending): {_log_safe(text)}")
            return
        try:
            self.game_writer.write((text + "\n").encode("utf-8"))
            self._note_sent(text)
        except Exception as e:
            logger.exception(f"Failed to write to game, re-queuing: {e}")
            self.pending_grants.append(text)

    def _toast_to_game(self, text: str) -> None:
        """Cosmetic-only TOAST: drop on the floor when the game is offline.
        Replaying a stale "X joined" or "Disconnected from AP server" toast
        the next time the game launches would be confusing. These are
        in-the-moment events, not durable state."""
        if self.game_writer is None or self.game_writer.is_closing():
            return
        try:
            self.game_writer.write(("TOAST " + text + "\n").encode("utf-8"))
        except Exception as e:
            logger.warning(f"TOAST drop ({text!r}): write failed: {e}")

    async def _sync_sound_randomizer(self, sd: dict) -> None:
        """Apply or restore the SFX binary patch for this seed, on the install
        that matches the seed's game mode. The file work runs in an executor so
        the 100+ MB rewrite never blocks the event loop."""
        enabled = bool(sd.get("sound_randomizer"))
        seed = int(sd.get("sound_seed") or 0)
        open_castle = sd.get("game_mode") == "open_castle"
        self.sound_randomizer_enabled = enabled
        self.sound_seed = seed if enabled else None

        install = _hp2_install_path(open_castle)
        if not install or not os.path.exists(sound_patch.package_path(install)):
            if not enabled:
                return  # nothing configured to restore; stay silent
            # Sound randomizer is on but this mode's install is unset/wrong: ask
            # the player to pick it once, then remember it in host.yaml.
            install = await self._prompt_install_folder(open_castle)
            if not install:
                return

        loop = asyncio.get_event_loop()
        try:
            if enabled:
                result = await loop.run_in_executor(
                    None, sound_patch.apply_patch, install, seed)
            else:
                result = await loop.run_in_executor(
                    None, sound_patch.restore_original, install)
        except (sound_patch.PatchError, OSError) as exc:
            logger.error(f"Sound randomizer: {exc}")
            return
        self._announce_sound_result(enabled, result)

    async def _prompt_install_folder(self, open_castle: bool) -> Optional[str]:
        """Pop a folder picker for the seed's game mode and persist the choice to
        host.yaml, so the player picks their install once. Returns the chosen
        folder (which contains system/HPSounds.u) or None if cancelled / no GUI."""
        mode = "open castle" if open_castle else "vanilla"
        field = "open_castle_install_folder" if open_castle else "vanilla_install_folder"
        try:
            from Utils import open_directory
        except Exception:
            logger.warning(
                f"Sound randomizer is on, but no folder picker is available here. "
                f"Set 'harry_potter_2_pc_options' -> '{field}' in host.yaml to your "
                f"{mode} install folder."
            )
            return None
        title = (f"Select your Harry Potter 2 {mode} install folder.")
        loop = asyncio.get_event_loop()
        chosen = await loop.run_in_executor(None, open_directory, title)
        if not chosen:
            logger.warning(
                f"Sound randomizer is on for this {mode} seed but no folder was "
                f"chosen. Reconnect to pick it, or set 'harry_potter_2_pc_options' "
                f"-> '{field}' in host.yaml."
            )
            return None
        if not os.path.exists(sound_patch.package_path(chosen)):
            logger.warning(
                f"'{chosen}' has no system\\HPSounds.u, so it is not a Harry Potter 2 "
                f"install folder. Not saved; reconnect to try again."
            )
            return None
        self._save_install_folder(field, chosen)
        return chosen

    def _save_install_folder(self, field: str, path: str) -> None:
        """Persist a picked install folder into host.yaml so the player is asked
        only once per mode."""
        try:
            import settings as ap_settings
            current = getattr(HP2World.settings, field)
            setattr(HP2World.settings, field, type(current)(path))
            ap_settings.get_settings().save()
            logger.info(f"Saved {field} to host.yaml: {path}")
        except Exception as exc:
            logger.warning(
                f"Picked '{path}' but could not save it to host.yaml ({exc}); set "
                f"'{field}' manually to avoid being asked again."
            )

    def _announce_sound_result(self, enabled: bool, result: str) -> None:
        # 'unchanged' / 'no-backup' need no message. A live game already loaded
        # the old package, so a change needs one restart; if the game is not up
        # yet, the next launch picks it up with no extra restart.
        if enabled and result == "patched":
            if self.game_writer is not None:
                self._toast_to_game("Sound randomizer applied. Restart to hear it.")
                logger.info("Sound randomizer applied. Restart Harry Potter to hear it.")
            else:
                logger.info("Sound randomizer applied; it loads when you launch Harry Potter.")
        elif not enabled and result == "restored":
            if self.game_writer is not None:
                self._toast_to_game("Original sounds restored. Restart to apply.")
                logger.info("Original sounds restored. Restart Harry Potter.")
            else:
                logger.info("Original sounds restored; original SFX load on next launch.")

    async def handle_game_connection(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        logger.info(f"Game connected from {peer}")
        self.game_writer = writer
        # Fresh game session — clear the per-session sent-index guard so the
        # HELLO re-forward / drain below repopulate it from scratch.
        self.sent_this_session = set()

        # Drain anything queued while the game wasn't connected (start
        # inventory grants delivered before game boot, items received during
        # a previous game-disconnect window, etc).
        if self.pending_grants:
            logger.info(f"Draining {len(self.pending_grants)} queued grant(s) to game")
            queued, self.pending_grants = self.pending_grants, []
            for line in queued:
                try:
                    writer.write((line + "\n").encode("utf-8"))
                    self._note_sent(line)
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
        if line.startswith("APPLIED "):
            # Mod confirms an item was applied to the live game and the
            # post-apply SaveGame() landed. Mark its AP index durably consumed
            # and persist the ledger to AP storage so a reconnect / save-load /
            # client restart never re-grants it.
            try:
                idx = int(line[len("APPLIED "):].strip())
            except ValueError:
                logger.warning(f"Unparseable APPLIED: {line!r}")
                return
            if idx not in self.consumed_indices:
                self.consumed_indices.add(idx)
                self._persist_ledger()
            return
        if line == "DRAIN_ROLLBACK":
            # Mod completed a death-revert: any item between the last save and
            # the death was un-applied by LoadGame 0, and its APPLIED ack was
            # buffered but never flushed. Anything in sent_this_session that
            # isn't durably consumed is exactly that set — drop it from the
            # session guard so _forward_all_received re-sends it, and the
            # post-reload drain re-applies it durably.
            unacked = self.sent_this_session - self.consumed_indices
            if unacked:
                self.sent_this_session -= unacked
                logger.info(f"DRAIN_ROLLBACK: re-forwarding {len(unacked)} unacked item(s) after death-revert")
                self._forward_all_received()
            else:
                logger.info("DRAIN_ROLLBACK: no unacked items in flight - no-op")
            return
        if line == "NEWGAME":
            # Mod observed a genuine new game (iGameState 0). Wipe the
            # consumed-index ledger (memory + AP storage) so the fresh
            # playthrough re-receives every item, then re-forward.
            # sent_this_session is deliberately NOT cleared: the mod's grant
            # queue / TCP session is continuous across a NEWGAME, so anything
            # already sent this session must not be re-sent (that would
            # double-queue → double-apply). Items skipped pre-NEWGAME because
            # they were in the stale prior-playthrough ledger are now forwarded
            # (consumed is empty); each index ends up sent exactly once. RESYNC
            # then re-asserts AP-granted spells against the fresh mod state
            # (default.APGrantedSpell may have been reset by the mod's open
            # castle entry path); the spell set itself is unchanged because
            # received_by_index still holds every spell AP has ever delivered.
            logger.info("NEWGAME: wiping durable ledger and re-forwarding all received items")
            self.consumed_indices = set()
            self._persist_ledger()
            self._send_resync_spells()
            self._forward_all_received()
            return
        if line == "HELLO":
            # Game (re)connected — re-forward every received item not yet
            # consumed (the sent_this_session guard, reset on this connect,
            # stops the pending-grants drain + this from double-sending).
            #
            self._forward_all_received()
            # Re-arm the declared seed mode. Sticky + idempotent mod-side, so
            # every HELLO (fresh launch / reconnect / cold load into a
            # sentinel-less level) re-asserts it. Sent in BOTH modes so the mod
            # can flag a seed/install mismatch; "open_castle" also re-latches
            # bOpenCastleMode.
            if self.seed_mode is not None:
                self._send_to_game("MODE " + self.seed_mode)
            # Re-arm the open castle Great Hall key thresholds. Sticky +
            # idempotent mod-side, so resending every HELLO covers fresh game
            # launches and reconnects without harm. No-op for vanilla /
            # pre-Connected.
            if self.open_castle_goalcfg:
                self._send_to_game("GOALCFG " + self.open_castle_goalcfg)
            # Re-arm the Tradersanity price mode. Sticky + idempotent mod-side;
            # is not None (not truthiness) so mode 0 (off) still re-arms and a
            # later seed that turns Tradersanity off is honoured.
            if self.tradersanity_cfg is not None:
                self._send_to_game("TRADECFG " + self.tradersanity_cfg)
            # Re-arm the skip-vendor-voices flag. Sticky + idempotent mod-side;
            # the mod re-applies the silence sweep on every level snapshot, so
            # a fresh launch / level change picks up the right state.
            self._send_to_game(f"SKIP_VENDOR_VOICES {1 if self.skip_vendor_voices else 0}")
            # Re-arm the quidditch-upgrades flag so Fred/George get the AP
            # icon + banner + hint only when their two locations exist as
            # AP checks for this seed.
            self._send_to_game(f"QUIDDITCH_UPGRADES {1 if self.quidditch_upgrades else 0}")
            # Re-push Tradersanity vendor hint item names to the mod. Sticky +
            # idempotent mod-side (cached per-slot on APCardWatcher), so
            # resending every HELLO covers fresh launches / reconnects.
            self._send_vendor_hints_to_mod()
            # Re-arm the Tradersanity per-vendor price factors. Sticky +
            # idempotent mod-side (writes a class-default byte table). Only
            # sent when Tradersanity is on — when off the mod never reads the
            # table, and an off seed should not be carrying stale factors.
            if self.tradersanity_prices_csv:
                self._send_to_game("TRADERPRICES " + self.tradersanity_prices_csv)
            # Re-arm the music randomizer enabled flag + pools + per-seed
            # salt. Sticky + idempotent mod-side. Always re-arm the flag
            # (so a fresh game launch knows the current state); only re-push
            # the seed + pool CSVs when enabled.
            self._send_to_game("MUSICRAND " + ("1" if self.music_randomizer_enabled else "0"))
            if self.music_randomizer_enabled:
                if self.music_seed is not None:
                    self._send_to_game(f"MUSICSEED {self.music_seed}")
                if self.music_pool_csv is not None:
                    self._send_to_game("MUSICPOOL " + self.music_pool_csv)
                if self.jingle_pool_csv is not None:
                    self._send_to_game("JINGLEPOOL " + self.jingle_pool_csv)
            # #3: re-push the appearance table. Sticky + idempotent mod-side,
            # so resending every HELLO re-arms a fresh game launch / reconnect.
            # is not None (not truthiness) so an all-native "" still re-arms.
            if self.appearance_csv is not None:
                self._send_to_game("APPEARANCE " + self.appearance_csv)
            # Re-arm the startup connection toast address. Sticky + idempotent
            # mod-side (the mod owns the once-per-launch / once-per-save-load
            # latch), so a fresh game launch or reconnect HELLO re-delivers
            # the address without re-toasting. None until AP-connected.
            if self.connected_address:
                self._send_to_game("CONNECTED " + self.connected_address)
            # Re-arm the checked-locations resync. Sticky + idempotent mod-side
            # (stamps are 0→1 only, no clears). `is not None` (not truthiness)
            # so the empty-string "no checks yet" payload still re-arms — the
            # mod overwrites any stale state from a prior session that way.
            if self.checked_csv is not None:
                self._send_to_game("CHECKED " + self.checked_csv)
            # Re-arm the durable spell-grant resync. Mirrors CHECKED's lifecycle:
            # sticky + idempotent mod-side, resent every HELLO so a fresh game
            # launch (mid-session reconnect / save-load) re-asserts the AP-grant
            # flags and re-adds spells the .usa dropped. Gated on ledger_loaded
            # because received_by_index is only known-complete once AP has sent
            # ReceivedItems and replied to our Get; a HELLO before that would
            # ship a stale empty list and wipe legit spells via the mod's
            # now-open gate.
            if self.ledger_loaded:
                self._send_resync_spells()
                self._send_resync_blocker_keys()
                self._send_resync_key_items()
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
        if line == "DEATH" or line.startswith("DEATH "):
            # Harry entered stateDead. Broadcast a DeathLink Bounce only while
            # tagged (death_link on) and outside the amnesty window — the mod
            # already skipped the outbound edge for an induced (incoming) kill
            # via its suppression latch, so anything reaching here is an
            # organic death. send_death stamps last_death_link itself.
            if not self.death_link_enabled or "DeathLink" not in self.tags:
                return
            if (time.time() - self.last_death_link) < DEATHLINK_AMNESTY_S:
                logger.info("DeathLink: outbound suppressed (within amnesty window)")
                return
            if not (self.server and self.slot is not None):
                logger.info("DeathLink: AP offline, dropping outbound death (not queued)")
                return
            # The DeathLink spec asks for a non-empty cause that contains the
            # player name (slot known here — the offline guard above ran), so
            # receiving games show which AP slot died, not the in-game avatar.
            me = self.player_names.get(self.slot, "Harry")
            cause = f"{me} got avada kadavra'd"
            logger.info(f"DeathLink: outbound death → Bounce ({cause})")
            await self.send_death(cause)
            self._toast_to_game("DeathLink sent")
            return
        if line.startswith("SAY "):
            # Cosmetic only: a ~1/100 spell-cast roll fired mod-side. Post a
            # random flavor line to multiworld chat. No dedupe / no location
            # semantics — purely a gag.
            await self._handle_spell_say(line[4:].strip())
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
        if line.startswith("VENDOR_OPENED "):
            try:
                location_id = int(line[len("VENDOR_OPENED "):].strip())
            except ValueError:
                logger.warning(f"Unparseable VENDOR_OPENED: {line!r}")
                return
            if not self.tradersanity_hint_on_open:
                return
            if location_id in self.hinted_vendor_locs:
                return
            if location_id not in self.server_locations:
                return
            self.hinted_vendor_locs.add(location_id)
            await self._send_or_queue_ap_msg(
                {"cmd": "LocationScouts",
                 "locations": [location_id],
                 "create_as_hint": 2},
                label=f"LocationScouts hint for AP location id {location_id} (VENDOR_OPENED)",
            )
            self._persist_vendor_hints()
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

    def _random_other_player(self) -> Optional[str]:
        """A random real player that isn't us, or None if there is no such
        player resolvable. Excludes our own slot, the Server pseudo-slot
        (slot 0), and group / item-link pseudo-slots (SlotType.group). When
        AP is offline self.slot is None — we can't reliably tell ourselves
        apart, so return None and let the caller fall back to "<Spell>!"."""
        if self.slot is None:
            return None
        names: list[str] = []
        for sid, name in self.player_names.items():
            if sid == self.slot or sid == 0:
                continue
            si = self.slot_info.get(sid) if self.slot_info else None
            if si is not None and si.type == SlotType.group:
                continue
            names.append(name)
        if not names:
            return None
        return random.choice(names)

    def _build_spell_flavor(self, spell_name: str) -> str:
        """Build the chat line for a cast spell. 50/50 between "<Spell>!" and
        "casts <Spell> on <other>" (a random other real player); AP prefixes
        our own slot name, so it's never in the body. Falls back to the plain
        form when there's no other player (solo / AP offline)."""
        forms = [f"{spell_name}!"]
        other = self._random_other_player()
        if other is not None:
            forms.append(f"casts {spell_name} on {other}")
        return random.choice(forms)

    async def _handle_spell_say(self, spell_name: str) -> None:
        """A ~1/100 spell-cast roll fired SAY mod-side — post a random flavor
        line to multiworld chat. Routed through the same offline-safe queue as
        checks so an AP-down gag is replayed on reconnect (never lost, never
        blocks the game). Purely cosmetic: no location / dedupe semantics."""
        msg = self._build_spell_flavor(spell_name)
        await self._send_or_queue_ap_msg(
            {"cmd": "Say", "text": msg},
            label=f"Say (spell-cast flavor for {spell_name!r})",
        )

    async def _send_or_queue_ap_msg(self, msg: dict, label: str) -> None:
        """Send an outbound AP message, or queue it for replay on next Connected.

        The mod's markers self-destroy on Touch so the location cannot be
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

    def _note_sent(self, line: str) -> None:
        """Record that a GRANT line was actually written to the game writer
        (immediate or via the offline-queue drain), so the HELLO re-forward and
        the drain don't double-send the same index before its APPLIED ack."""
        if line.startswith("GRANT "):
            try:
                self.sent_this_session.add(int(line.split(" ", 2)[1]))
            except (IndexError, ValueError):
                pass

    def _persist_ledger(self) -> None:
        """Write the consumed-index set back to AP server Data Storage. Routed
        through the offline-safe queue so an AP blip can't lose it (replayed on
        reconnect). want_reply=False — single writer, no read-back needed."""
        if self.ledger_key is None:
            return
        asyncio.create_task(self._send_or_queue_ap_msg(
            {"cmd": "Set", "key": self.ledger_key, "default": [],
             "want_reply": False,
             "operations": [{"operation": "replace",
                             "value": sorted(self.consumed_indices)}]},
            label=f"persist durable ledger ({len(self.consumed_indices)} index(es))",
        ))

    def _persist_vendor_hints(self) -> None:
        """Write the already-hinted Tradersanity location-id set back to AP
        server Data Storage so a reconnect or client restart never re-broadcasts
        the same hint. Same offline-safe queue + replace semantics as the
        durable ledger."""
        if self.vendor_hint_key is None:
            return
        asyncio.create_task(self._send_or_queue_ap_msg(
            {"cmd": "Set", "key": self.vendor_hint_key, "default": [],
             "want_reply": False,
             "operations": [{"operation": "replace",
                             "value": sorted(self.hinted_vendor_locs)}]},
            label=f"persist vendor-hint set ({len(self.hinted_vendor_locs)} loc(s))",
        ))

    @property
    def granted_spell_names(self) -> set[str]:
        """The set of spell item names this slot has ever received from AP,
        derived from the cumulative received-items dict on read. AP replays
        the full ReceivedItems on every Connected, so this is authoritative
        without a parallel Data Storage record. Read by `_send_resync_spells`
        each time it pushes a RESYNC_SPELLS line."""
        return {
            name
            for item in self.received_by_index.values()
            for name in (self.item_names.lookup_in_game(item.item, GAME_NAME),)
            if name in SPELL_ITEM_NAMES_SET
        }

    @property
    def granted_blocker_key_names(self) -> set[str]:
        """Bookcase-blocker keys this slot has received from AP, derived the
        same way as `granted_spell_names`. Read by `_send_resync_blocker_keys`
        on every Connected + game HELLO."""
        return {
            name
            for item in self.received_by_index.values()
            for name in (self.item_names.lookup_in_game(item.item, GAME_NAME),)
            if name in BLOCKER_KEY_NAMES_SET
        }

    @property
    def granted_key_item_names(self) -> set[str]:
        """Potion-ingredient key items (Boomslang / Bicorn / BitOGoyle) this
        slot has received from AP. Always empty today — these names are not in
        items.yaml — but the membership test mirrors the spell / blocker-key
        pattern so a future randomization picks up save-load survivability
        without further wiring."""
        return {
            name
            for item in self.received_by_index.values()
            for name in (self.item_names.lookup_in_game(item.item, GAME_NAME),)
            if name in KEY_ITEM_NAMES_SET
        }

    def _send_resync_spells(self) -> None:
        """Push the derived spell ledger to the mod as a single RESYNC_SPELLS
        line. Sticky + idempotent mod-side; sent on every Connected (Retrieved)
        and every game HELLO. Empty payload still opens the mod's wipe gate, so
        a slot with no spells received yet correctly reverts vanilla-engine
        F/L/A on the very first tick of post-resync revert."""
        csv = ",".join(sorted(self.granted_spell_names))
        # Bare "RESYNC_SPELLS" (no trailing space) is the empty-list form the
        # mod expects (APIPCActor.HandleLine has a separate exact-match branch).
        if csv:
            self._send_to_game(f"RESYNC_SPELLS {csv}")
        else:
            self._send_to_game("RESYNC_SPELLS")

    def _send_resync_blocker_keys(self) -> None:
        """Push the derived bookcase-blocker-key ledger to the mod as a single
        RESYNC_BLOCKERKEYS line. Sticky + idempotent mod-side; sent on every
        Connected (Retrieved) and every game HELLO. The mod re-stamps
        default.APGrantedBlockerKey[] AND destroys any matching live bookcase
        blocker, so a cold load that wiped the class-defaults isn't soft-locked
        by the consumed-indices ledger blocking GRANT replay. Covers both
        modes — open castle (per-key blocker) and vanilla (cumulative chain
        plus standalone Duelling/Quidditch)."""
        csv = ",".join(sorted(self.granted_blocker_key_names))
        if csv:
            self._send_to_game(f"RESYNC_BLOCKERKEYS {csv}")
        else:
            self._send_to_game("RESYNC_BLOCKERKEYS")

    def _send_resync_key_items(self) -> None:
        """Push the derived potion-key-item ledger to the mod as a single
        RESYNC_KEYITEMS line. Always empty today (none of the three names are
        in items.yaml); wired up so future randomization of any of them
        inherits the spell / blocker-key save-load survivability."""
        csv = ",".join(sorted(self.granted_key_item_names))
        if csv:
            self._send_to_game(f"RESYNC_KEYITEMS {csv}")
        else:
            self._send_to_game("RESYNC_KEYITEMS")

    def _forward_one(self, idx: int, item) -> None:
        """Forward one received item to the game as `GRANT <idx> <payload>`,
        unless its index is already durably consumed (applied in a prior
        session, per the AP-storage ledger) or already sent this game session
        (awaiting its APPLIED ack). item is a NetworkItem (item, location,
        player, flags)."""
        if idx in self.consumed_indices or idx in self.sent_this_session:
            return
        item_name = self.item_names.lookup_in_game(item.item, GAME_NAME) or f"item_id_{item.item}"
        # Cards forward as the UScript class name so ApplyGrant can
        # DynamicLoadObject + SetCardOwner; everything else forwards its raw
        # item name through ApplyGrant's spell / key-item / filler branches.
        ucls = ITEM_NAME_TO_CARD_CLASS.get(item_name)
        payload = ucls if ucls else item_name
        sender_name = self.player_names.get(item.player, f"player_{item.player}")
        logger.info(
            f"Forwarding item idx={idx} {item_name} (id={item.item}) "
            f"from {sender_name} → GRANT {idx} {payload}|{sender_name}"
        )
        self._send_to_game(f"GRANT {idx} {payload}|{sender_name}")

    def _forward_all_received(self) -> None:
        """Re-evaluate every received item and forward the ones not yet
        consumed. Called after the ledger loads, on HELLO, and after a NEWGAME
        wipe. Idempotent via the consumed / sent-this-session guards."""
        if not self.ledger_loaded:
            return
        for idx in sorted(self.received_by_index):
            self._forward_one(idx, self.received_by_index[idx])

    def _appearance_code_for_item(self, ni) -> int:
        """Resolve a scouted NetworkItem to the mod appearance code.

        ni.player is the receiving/owner slot (LocationScouts semantics). A
        non-HP2 owner (incl. group / item-link slots) → AP-logo plate, arrow
        if the foreign item is progression or trap. An HP2 owner → that HP2
        item's own art (card 1..101 / spell 1000+idx / filler 2001..2008 /
        equipment 3001..3002 / open castle key 3003), or 0 (native) for an HP2 item
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

    def _rebuild_checked_csv(self) -> None:
        """Recompute the CHECKED resync payload from this slot's
        checked_locations, intersected with the slot's HP2 location universe.
        Pushed every game HELLO so the mod can stamp class-default
        LocationChecked[] / NonCardLocationChecked[] on a fresh process —
        those arrays are process-lifetime only. The intersect mirrors the
        appearance scout: server_locations is the authoritative per-slot
        universe (missing | checked), so an apId outside it is not ours and
        would only be noise to the mod. Diff against the cached payload to
        suppress no-op resends from RoomUpdates that didn't touch our slot."""
        if not self.server_locations:
            return
        valid = set(LOCATION_NAME_TO_ID.values()) & set(self.server_locations)
        ids = sorted(set(self.checked_locations) & valid)
        csv = ",".join(str(i) for i in ids)
        if csv == self.checked_csv:
            return
        self.checked_csv = csv
        logger.info(f"Checked-locations resync rebuilt: {len(ids)} location(s)")
        self._send_to_game("CHECKED " + csv)

    def _send_vendor_hints_to_mod(self) -> None:
        """Push the resolved item name for each Tradersanity vendor location to
        the mod via HINT IPC lines, so the in-trade label can read the actual
        item name instead of the generic "Archipelago Item" fallback. Gated on
        tradersanity_hint_on_open: an off-hint seed keeps the mystery and the
        mod sees no HINT, so the label stays generic. Called after every
        LocationInfo (scout response) and on HELLO so a fresh game session
        re-receives the cache."""
        if not self.tradersanity_hint_on_open:
            return
        if not self.locations_info:
            return
        tradersanity_ids = {
            LOCATION_NAME_TO_ID[name]
            for name, group in LOCATION_GROUPS.items()
            if group == "Tradersanity"
        }
        # Fred (Nimbus 2001) and George (Quidditch Armour) are AP-tracked
        # vendors gated on enable_quidditch_upgrades, so they ride on the same
        # hint pipeline as the 13 Tradersanity vendors when the option is on.
        if self.quidditch_upgrades:
            tradersanity_ids.add(5760005)  # Castle Exterior - Nimbus 2001
            tradersanity_ids.add(5760006)  # Castle Exterior - Quidditch Armour
        for loc_id in tradersanity_ids:
            ni = self.locations_info.get(loc_id)
            if ni is None:
                continue
            item_name = self.item_names.lookup_in_slot(ni.item, ni.player)
            if not item_name:
                continue
            # "<slot>'s <item>" so the label reads as a possessive sentence
            # rather than just an item name in a vacuum — makes the foreign
            # ownership obvious. For our own items we use the slot name too;
            # if it gets noisy we can branch on `ni.player == self.slot`
            # and drop the prefix.
            player_name = self.player_names.get(ni.player, f"player_{ni.player}")
            payload = f"{player_name}'s {item_name}"
            self._send_to_game(f"HINT {loc_id} {payload}")

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
            f"({len(self.pending_grants)} pending grant(s), "
            f"{len(self.pending_ap_outbound)} pending AP msg(s), "
            f"{len(self.checked_locations_seen)} checked location(s), "
            f"goal_sent={self.goal_sent})"
        )
        self.pending_grants = []
        self.pending_ap_outbound = []
        self.checked_locations_seen = set()
        self.goal_sent = False
        # Drop the prior seed's durable-ledger state; the new seed is a
        # different AP server/room, so the next Connected recomputes ledger_key
        # and re-fetches its own consumed-index set from AP storage. Clearing
        # received_by_index also clears the spell ledger (it's a @property
        # derived from this dict).
        self.ledger_key = None
        self.consumed_indices = set()
        self.ledger_loaded = False
        self.received_by_index = {}
        self.sent_this_session = set()
        # #3: drop the prior seed's appearance table so the next Connected's
        # scout rebuilds it from scratch (item placement differs per seed).
        self.appearance_csv = None
        # Drop the prior seed's checked-locations resync; the new seed has its
        # own checked_locations universe (different ids, different progress).
        self.checked_csv = None

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
    ctx.server_task = asyncio.create_task(server_loop(ctx), name="server loop")
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
