"""HP2PC_AP. Archipelago-aware client (bundled apworld component).

Subclasses Archipelago's CommonContext to speak the real AP protocol over
WebSocket against a hosted seed, while also accepting a local TCP connection
from the HP2 mod and bridging messages between the two.

Launched via the Archipelago launcher's "HP2 PC Client" button, or directly
during dev from inside the Archipelago repo:
    py -3.12 -m worlds.harry_potter_2_pc.Client --name HP2_Test --connect localhost:38281

Mod-side protocol (newline-delimited text):
    HELLO                       (game → client, on connect)
    CHECK <id>                  (game → client, on card pickup, game-side card id 1..101)
    CHECK_LOCID <id>            (game → client, on secret/star pickup, raw AP location id)
    CHECK_SPELL <name>          (game → client, on spell learned)
    CHECK_KEYITEM <name>        (game → client, on Boomslang/Bicorn pickup or BitOGoyle interaction)
    GOAL_COMPLETE               (game → client, when the end-game latch sets; also replayed
                                on every bridge connect while it holds, so a goal reached
                                offline still registers)
    RINGOUT <signed_int>        (game → client, local bean total changed organically)
    SAY <text>                  (game → client, ~1/100 on spell cast, cosmetic chat)
    DEATH [cause]               (game → client, Harry entered stateDead, DeathLink out)
    VENDOR_OPENED <locId>       (game → client, player opened a Tradersanity vendor dialogue → broadcast hint)
    APPLIED <index>             (game → client, item at AP index applied → mark durably consumed)
    NEWGAME                     (game → client, genuine new game (iGameState 0) → wipe ledger)
    CHECKEDOUT <id_csv>         (game → client, on bridge connect: AP location ids the mod has
                                locally checked → replay to AP for any the server is missing)
    BEANSTATE_BEGIN             (game → client, start of a chunked bean-room ledger snapshot,
                                sent on leaving the open-castle bean room)
    BEANSTATE <chunk>           (game → client, one verbatim slice of the ledger; the whole line
                                outgrows the mod's per-line TcpLink cap, so it ships in chunks)
    BEANSTATE_END               (game → client, end of the snapshot: concatenate the chunks and
                                persist to AP storage so the room survives a restart)
    GRANT <index> <payload>\x1f<segrecord>  (client → game, forward item received; index = AP
                                ReceivedItems index; \x1f splits the apply payload from a
                                colourised toast segment record)
    SENT <segrecord>            (client → game, colourised "we sent X to Y" toast for items routed to other slots)
    RINGIN <signed_int>         (client → game, net remote RingLink delta to apply)
    DEATHLINK                   (client → game, a linked player died, kill Harry)
    TRAPLINK <name>|<source>    (client → game, a linked player's trap, applied via the grant
                                drain as an index-less grant)
    CONNECTED <host:port>       (client → game, AP server address for startup toast; sticky, every HELLO)
    CHECKED <id_csv>            (client → game, comma-separated AP location ids the server
                                already has as checked; sticky, every HELLO)
    RESYNC_CARDS <class_csv>    (client → game, wizard-card UScript class names ever received;
                                re-asserts CardOwner_Harry; sticky, every Connected + HELLO)
    RESYNC_BEANROOM <payload>   (client → game, open-castle bean-room ledger from AP storage;
                                merges dispensers/floor, restores drops on cold load; every
                                Connected + HELLO)
    TOAST <text>                (client → game, yellow system toast: DeathLink out, AP disconnect, randomizer notices)
    TOASTW <text>               (client → game, white lifecycle toast: Join/Part, Goal by other slot, inbound DeathLink)
    segrecord = `<roleChar><text>` segments joined by \x1e; roles s=our slot o=other
                g/u/t/f=item-by-flag l=location w=white n=newline

Durable-grant ledger: the set of applied AP indices is persisted in AP server
Data Storage (key HP2PC_AP:{team}:{slot}), loaded on Connected, written on each
APPLIED, wiped on NEWGAME. The mod's .usa cannot persist mod data (M212), so AP
storage is the source of truth for which indices have already been forwarded.

Durable AP-grant resyncs (spells, bookcase-blocker keys, potion key items,
wizard cards): each set of granted item names is derived live from AP's
cumulative ReceivedItems list (which the server replays in full on every
Connected) and pushed to the mod as RESYNC_SPELLS / RESYNC_BLOCKERKEYS /
RESYNC_KEYITEMS / RESYNC_CARDS on every Connected and every game HELLO. The mod
re-stamps the matching class-default flag arrays (APGrantedSpell /
APGrantedBlockerKey / APGrantedKeyItem / APGrantedCard) and restores any live
game state the .usa save dropped (spellbook entries, bookcase blocker actors,
Harry's ingredient StatusItems, folio card ownership), so a process restart that
wiped the compiled class-defaults can never strand the slot. The consumed-indices
ledger would otherwise block any GRANT replay for these items. Cards additionally
have no .usa-backed store at all, so the resync is also their save-load recovery
within a single process (the gold-card-room "tracker enterable but folio short" fix).

AP-side protocol: standard Archipelago WebSocket (handled by CommonContext).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import random
import subprocess
import sys
import time
import urllib.parse
import warnings
from typing import Optional, TYPE_CHECKING

# Silence the upstream setuptools deprecation that fires every time AP imports
# pkg_resources (Archipelago/ModuleUpdate.py:76). Must run before importing
# CommonClient below so the filter is in place when the warning would emit.
warnings.filterwarnings("ignore", message=".*pkg_resources is deprecated.*")

import CommonClient
from CommonClient import (ClientCommandProcessor, CommonContext,
                          get_base_parser, gui_enabled, server_loop)
from NetUtils import ClientStatus, SlotType

from . import HP2World, dialogue_patch, music_patch, sound_patch
from .items import (CARD_CLASS_TO_ITEM_NAME, FILLER_APPEARANCE_CODE,
                    ITEM_CLASSIFICATIONS, ITEM_GROUPS)
from .locations import (CARD_CLASS_TO_LOCATION_NAME,
                        CARD_GAME_ID_TO_LOCATION_NAME, LOCATION_GROUPS,
                        LOCATION_NAME_TO_ID)
from .ue1_package import PatchError

if TYPE_CHECKING:
    import kvui

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


def _auto_launch_enabled() -> bool:
    """Whether the client launches the matching install's Game.exe on connect.
    Read at call time so a host.yaml edit needs no client restart. On read error,
    default to off so a misread never surprise-launches the game."""
    try:
        return bool(HP2World.settings.auto_launch_game)
    except Exception:
        return False


# /reroll overrides per randomizer kind ("sound" / "music"), keyed by
# "<ap seed>:<slot>" so each multiworld keeps its own reshuffle and the reroll
# survives the reconnect after the restart. Kept in small JSON sidecars in the AP
# user folder, not host.yaml (per-seed state, not a setting).
def _reroll_store_path(kind: str) -> str:
    from Utils import user_path
    return user_path(f"hp2pc_ap_{kind}_rerolls.json")


def _load_rerolls(kind: str) -> dict:
    try:
        with open(_reroll_store_path(kind), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _get_reroll(kind: str, key: str) -> Optional[int]:
    value = _load_rerolls(kind).get(key)
    return int(value) if value is not None else None


def _save_reroll(kind: str, key: str, seed: int) -> None:
    data = _load_rerolls(kind)
    data[key] = int(seed)
    with open(_reroll_store_path(kind), "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


class _AudioKind:
    """One client-side audio randomizer: which install file it patches and how
    the client talks about it. Lets the apply / restore / reroll plumbing treat
    sound, music, and dialogue uniformly instead of branching per kind."""

    def __init__(self, noun, thing, backup, reroll_cmd, patch, present, mode_aware=False):
        self.noun = noun              # "Sound randomizer"
        self.thing = thing            # "sounds" (lower-case, for sentences)
        self.backup = backup          # "HPSounds.u.orig backup"
        self.reroll_cmd = reroll_cmd  # "/reroll_sounds"
        self.patch = patch            # module: apply_patch / restore_original / package_path
        self.present = present        # (install) -> bool: the target file/folder is there
        self.mode_aware = mode_aware  # sound/dialogue carry a shuffle mode on top of a seed


# Sound and dialogue repoint a UE1 package, music swaps loose oggs; all three
# back up once, apply on Connected, restore when off, and reshuffle on /reroll_*.
# mode_aware kinds (sound, dialogue) carry a per-seed mode (self.audio_mode).
_AUDIO_KINDS = {
    "sound": _AudioKind(
        "Sound randomizer", "sounds", "HPSounds.u.orig backup", "/reroll_sounds",
        sound_patch, lambda p: os.path.exists(sound_patch.package_path(p)),
        mode_aware=True),
    "music": _AudioKind(
        "Music randomizer", "music", "Music backup", "/reroll_music",
        music_patch, lambda p: os.path.isdir(music_patch.music_dir(p))),
    "dialogue": _AudioKind(
        "Dialogue randomizer", "dialogue", "AllDialog.uax.orig backup", "/reroll_dialogue",
        dialogue_patch, lambda p: os.path.exists(dialogue_patch.package_path(p)),
        mode_aware=True),
}

# All patch modules raise ue1_package.PatchError. OSError covers a write that
# fails outside the friendly-message path.
_PATCH_ERRORS = (PatchError, OSError)


# All wizard-card item names, derived from ITEM_GROUPS (items.py) so it can never
# drift. Used by /progress to count cards in received items.
CARD_ITEM_NAMES_SET = frozenset(
    ITEM_GROUPS.get("Cards (Bronze)", [])
    + ITEM_GROUPS.get("Cards (Silver)", [])
    + ITEM_GROUPS.get("Cards (Gold)", [])
)
# Base AP id for the level-completion locations (the story/challenge levels plus
# the Gold Card Room). The count derives from the data so it cannot drift when a
# level is added. idx = AP id - LEVEL_COMPLETION_BASE.
LEVEL_COMPLETION_BASE = 5760700
LEVEL_COMPLETION_COUNT = sum(1 for g in LOCATION_GROUPS.values() if g == "LevelCompletions")
# Full set sizes for the duels and Quidditch goal clauses, derived from the data
# so they cannot drift. Those two goal options are enable flags (win-all), not
# counts, so /progress shows these as the have/need denominator when the flag is set.
DUEL_COUNT = sum(1 for g in LOCATION_GROUPS.values() if g == "Duels")
QUIDDITCH_MATCH_COUNT = sum(1 for g in LOCATION_GROUPS.values() if g == "QuidditchMatches")
# Trap item names, from ITEM_GROUPS (items.py) so it can never drift. Used by
# the #3 marker-appearance classifier. Every
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
# Deliberately off the Archipelago server default (38281). The client binds this
# port for the game IPC listener; a player hosting a local AP server grabs 38281
# first, which would block the bind and silently strand the game. 42779 is far
# enough away that incrementing a busy host port never reaches it. Must match the
# mod's APIPCActor.Addr.Port.
GAME_TCP_PORT = 42779

# DeathLink race-insurance amnesty. An inbound death within this window
# of the last death in either direction (CommonContext.last_death_link, stamped
# by send_death and on_deathlink) is treated as simultaneity and not bounced
# into the game; an outbound DEATH within it is not re-broadcast. The
# deterministic loop is handled mod-side by the suppression latch. This only
# mops up genuine within-a-round-trip races.
DEATHLINK_AMNESTY_S = 2.0

# Map UScript spell name (as fired by APCardWatcher's CHECK_SPELL) to the
# AP location it represents. Only the 4 non-starter spells have classroom
# locations and so live in this map. Each is taught after its classroom's
# spell challenge. Story order: Rictusempra (Lockhart#1) → Skurge (Flitwick)
# → Diffindo (Sprout) → Spongify (Lockhart#2). Lumos/Flipendo/Alohomora have
# no classroom location; harry.uc:335-337 adds them to every fresh Harry, the
# mod's Snapshot+revert wipes them unless AP has granted them, and the AP
# grant restores them. Whether they're starters depends on `starting_spells`.
# See locations.py.
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

# Spell appearance index. MUST match APCardWatcher.SpellNames[] order
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

# Filler appearance code: name -> the mod's frozen 2001+ prop code, defined in
# items.py so it lives with the id space and stays name-keyed (it never shifts
# when the ITEM_GROUPS "Filler" order changes).
FILLER_CODE = FILLER_APPEARANCE_CODE

# Equipment appearance code: vanilla HProp pickups morphed to their own
# vanilla mesh, same as cards/spells/filler (mod codes 3001..3002).
EQUIPMENT_CODE = {'Nimbus 2001': 3001, 'Quidditch Armour': 3002}

# Bookcase-blocker key appearance code. The 14 region keys all share the
# vanilla "silver key" FX sprite (mod code 3003). Sourced from the canonical
# ITEM_GROUPS entry so the set never drifts from items.yaml.
KEY_CODE = {name: 3003 for name in ITEM_GROUPS['Blocker Keys']}

# Foreign (non-HP2) item codes. The only surviving #1 contribution: the
# AP-logo plate, arrow variant when the foreign item is progression or trap
# (progression_skip_balancing collapses to the progression bit), plain
# otherwise. This is the sole place the classification arrow is computed.
APPEARANCE_FOREIGN_PLAIN = 9000
APPEARANCE_FOREIGN_ARROW = 9001

# NetworkItem.flags classification bits (AP ItemClassification). Distinct from
# the connection-time items_handling bitfield, which happens to share literals.
ITEM_FLAG_PROGRESSION = 0b001
ITEM_FLAG_USEFUL = 0b010
ITEM_FLAG_TRAP = 0b100
ITEM_FLAG_ANY_CLASSIFIED = ITEM_FLAG_PROGRESSION | ITEM_FLAG_USEFUL | ITEM_FLAG_TRAP

logger = logging.getLogger("HP2Client")
# The Kivy client only renders loggers wired into its on-screen tabs ("Client").
# HP2Client goes to the log file only, so user-facing randomizer messages (apply /
# restore / reroll / errors the player must act on) use this so they show in the
# client window, not just the log file.
ui_logger = logging.getLogger("Client")


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
    def _restore_audio(self, kind: str) -> None:
        spec = _AUDIO_KINDS[kind]
        installs = []
        for mode, open_castle in (("vanilla", False), ("open castle", True)):
            path = _hp2_install_path(open_castle)
            if path and spec.present(path):
                installs.append((mode, path))
        if not installs:
            self.output("No install is configured. Set 'harry_potter_2_pc_options' -> "
                        "vanilla_install_folder / open_castle_install_folder in host.yaml.")
            return
        for mode, path in installs:
            try:
                result = spec.patch.restore_original(path)
            except _PATCH_ERRORS as exc:
                self.output(f"{mode}: restore failed: {exc}")
                continue
            if result == "restored":
                self.output(f"{mode}: original {spec.thing} restored. Restart Harry Potter if it is running.")
            elif result == "unchanged":
                self.output(f"{mode}: already original.")
            else:
                self.output(f"{mode}: no {spec.backup} found; nothing to restore.")

    def _reroll_audio(self, kind: str) -> None:
        ctx: "HP2Context" = self.ctx
        spec = _AUDIO_KINDS[kind]
        if not ctx.audio_enabled[kind]:
            self.output(f"Reroll needs a connected seed with the {kind} randomizer on.")
            return
        install = _hp2_install_path(ctx.is_open_castle)
        if not install or not spec.present(install):
            self.output("No valid install folder for this seed's mode yet. Reconnect "
                        "and pick it first.")
            return
        self.output(f"Reshuffling {spec.thing}. Restart Harry Potter once it finishes.")
        asyncio.create_task(ctx._reroll(kind, install))

    def _cmd_restore_sounds(self) -> bool:
        """Restore the original SFX from backup for every configured install,
        without connecting to a seed. Takes effect on the next game launch."""
        self._restore_audio("sound")
        return True

    def _cmd_restore_music(self) -> bool:
        """Restore the original music from backup for every configured install,
        without connecting to a seed. Takes effect on the next game launch."""
        self._restore_audio("music")
        return True

    def _cmd_reroll_sounds(self) -> bool:
        """Reshuffle the sound randomizer with a fresh seed (e.g. if a swapped
        sound is annoying). Remembered for this seed, so it sticks across
        restarts. Takes effect on the next game launch."""
        self._reroll_audio("sound")
        return True

    def _cmd_reroll_music(self) -> bool:
        """Reshuffle the music randomizer with a fresh seed. Remembered for this
        seed, so it sticks across restarts. Takes effect on the next game launch."""
        self._reroll_audio("music")
        return True

    def _cmd_restore_dialogue(self) -> bool:
        """Restore the original dialogue from backup for every configured install,
        without connecting to a seed. Takes effect on the next game launch."""
        self._restore_audio("dialogue")
        return True

    def _cmd_reroll_dialogue(self) -> bool:
        """Reshuffle the dialogue randomizer with a fresh seed, keeping the seed's
        shuffle mode. Remembered for this seed, so it sticks across restarts. Takes
        effect on the next game launch."""
        self._reroll_audio("dialogue")
        return True

    def _cmd_play(self) -> bool:
        """Launch Harry Potter for the connected seed's mode (vanilla or open
        castle). The client already auto-launches on connect; use /play if you
        turned that off (auto_launch_game), or to relaunch after closing the game.
        Waits for any in-flight randomizer patch first."""
        ctx: "HP2Context" = self.ctx
        if ctx.seed_mode is None:
            self.output("Connect to a seed first, so the client knows which version to launch.")
            return True
        asyncio.create_task(ctx._launch_game_manual())
        return True

    def _cmd_hint(self, category: str = "", tier: str = "") -> bool:
        """Hint your next in-logic item of a kind, spending hint points on it
        exactly like !hint. Usage: /hint spell | /hint key | /hint card
        [bronze|silver|gold]. Picks the earliest in-logic item of that kind you
        have not collected yet. Bare /hint card follows the seed goal: any card
        when the goal counts cards, silver otherwise."""
        ctx: "HP2Context" = self.ctx
        if ctx.server is None or ctx.slot is None:
            self.output("Connect to a seed first, so /hint knows your items.")
            return True
        if not ctx.hint_order:
            self.output("This seed carries no /hint data (generated before /hint "
                        "existed). Use !hint <item> instead.")
            return True
        kind = category.lower().rstrip("s")
        if kind not in ("spell", "key", "card"):
            self.output("Usage: /hint spell | /hint key | /hint card "
                        "[bronze|silver|gold]")
            return True
        candidates = list(ctx.hint_order.get(kind, []))
        label = kind
        if kind == "card":
            tier_groups = {
                "bronze": "Cards (Bronze)",
                "silver": "Cards (Silver)",
                "gold": "Cards (Gold)",
            }
            wanted_tier = tier.lower().rstrip("s")
            if wanted_tier:
                if wanted_tier not in tier_groups:
                    self.output("Card tier must be bronze, silver or gold.")
                    return True
                wanted = frozenset(ITEM_GROUPS.get(tier_groups[wanted_tier], []))
                candidates = [n for n in candidates if n in wanted]
                label = f"{wanted_tier} card"
            elif self._card_goal_counts_all_tiers():
                label = "card"
            else:
                wanted = frozenset(ITEM_GROUPS.get("Cards (Silver)", []))
                candidates = [n for n in candidates if n in wanted]
                label = "silver card"
        elif tier:
            self.output(f"/hint {kind} takes no extra argument.")
            return True
        if not candidates:
            self.output(f"This seed has no {label}s to hint.")
            return True
        received = {
            ctx.item_names.lookup_in_game(item.item, GAME_NAME)
            for item in ctx.received_by_index.values()
        }
        remaining = [name for name in candidates if name not in received]
        if not remaining:
            self.output(f"You already have every {label}.")
            return True
        target = remaining[0]
        self.output(f"Hinting your next {label}: {target}")
        # Reached only while connected (guarded above), so this !hint frame
        # sends now; the offline queue in _send_or_queue_ap_msg is not used here.
        asyncio.create_task(ctx._send_or_queue_ap_msg(
            {"cmd": "Say", "text": f"!hint {target}"},
            label=f"/hint request for {target!r}",
        ))
        return True

    def _card_goal_counts_all_tiers(self) -> bool:
        """Bare /hint card default. Open castle with a card-count goal treats any
        tier as progress, so hint the next card of any tier. Otherwise (vanilla,
        or open castle with no card goal) only silver cards gate anything, so
        default to silver."""
        ctx: "HP2Context" = self.ctx
        if not ctx.is_open_castle or not ctx.open_castle_goalcfg:
            return False
        try:
            return int(ctx.open_castle_goalcfg.split(",")[0]) > 0
        except (ValueError, IndexError):
            return False

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
        # duels_need / quid_need arrive as 0/1 enable flags (win-all clauses),
        # so the displayed denominator is the full set size when enabled.
        duels_need = DUEL_COUNT if duels_need else 0
        quid_need = QUIDDITCH_MATCH_COUNT if quid_need else 0

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
        # A clause left at need==0 is disabled and passes trivially (have >= 0),
        # so this matches the mod's GoalSatisfied AND over the enabled clauses.
        done = (cards_have >= cards_need and spells_have >= spells_need
                and levels_have >= levels_need and duels_have >= duels_need
                and quid_have >= quid_need)
        # Name the endpoint only once every clause passes and the Great Hall has
        # opened, matching the pause-menu panel. Hidden until then so the summary
        # reads as pure clause progress.
        if done:
            self.output("Great Hall open - go finish!")
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
        # Outbound location checks and goal completion ride CommonContext's own
        # resend-on-reconnect machinery rather than a parallel set. Every check
        # is added to self.locations_checked (a framework set the server replays
        # for us on every Connected and on a Sync index-mismatch); the goal sets
        # self.finished_game (the framework re-asserts CLIENT_GOAL on every
        # Connected). Both survive reset_server_state, so a check or goal sent
        # while AP was unreachable is reconciled on reconnect with no custom
        # queue. self.locations_checked also doubles as the per-check dedupe set.
        # FIFO of GRANT lines accumulated while no game is connected (start
        # inventory delivered before game boot, mid-session game crash, etc).
        # Drained by handle_game_connection on each new game connect.
        self.pending_grants: list[str] = []
        # Outbound AP messages queued while the AP server is offline. Drained
        # on every successful Connected. In-memory only. A client crash
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
        # Current map the player is in, mirrored to AP Data Storage under
        # level_key (HP2PC_AP_level:{team}:{slot}) so the PopTracker can follow
        # the player by reading/notifying on that key. The mod sends LEVEL on
        # each transition and replays it on bridge reconnect.
        self.level_key: Optional[str] = None
        self.current_level: Optional[str] = None
        # Open-castle bean-room ledger, persisted in AP Data Storage under
        # beanroom_key (HP2PC_AP_beanroom:{team}:{slot}) so the room's collected /
        # opened state survives a game restart (the .usa can't hold mod data on
        # M212). The mod sends BEANSTATE on leaving the room; we Get + replay it
        # to the mod (RESYNC_BEANROOM) on every connect / HELLO.
        self.beanroom_key: Optional[str] = None
        self.beanroom_state: str = ""
        # Accumulator for a chunked BEANSTATE snapshot. The mod sends the ledger
        # as BEANSTATE_BEGIN / BEANSTATE <chunk> ... / BEANSTATE_END (its single
        # line outgrows the mod's per-line TcpLink transmit cap); chunks are
        # concatenated verbatim here and committed to beanroom_state on END.
        self._beanstate_accum: str = ""
        self.beanroom_loaded: bool = False
        # When True, our in-memory consumed_indices wins over the server's stored
        # value on the next Retrieved (we overwrite the server instead of merging).
        # Set by the NEWGAME wipe so a stale server ledger (e.g. a wipe Set lost
        # to a dying socket) can't resurrect consumed indices and strand the
        # fresh playthrough. False the rest of the time, when the load instead
        # unions (preserving any locally-applied index whose persist was lost).
        self._ledger_client_authoritative: bool = False
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
        # NOT a separate Data Storage record. It is derived live from
        # received_by_index by the `granted_spell_names` property. AP's
        # cumulative ReceivedItems replay on every Connected is the source of
        # truth, so an already-consumed spell index (never re-forwarded as a
        # GRANT) still re-asserts as `RESYNC_SPELLS` on every connect/HELLO
        # via the property, covering the .usa save-load that dropped the
        # SpellBook[] class ref and the cold mod-process boot that reset
        # default.APGrantedSpell[].
        # Identity (seed_name, slot name) of the connection whose per-slot state
        # we currently hold. On a change to either, _reset_connection_state wipes
        # that state so a long-running client never replays one playthrough's
        # checks / items / goal to the next:
        #   - seed_name change → a different multiworld (the common case).
        #   - slot-name change → switching slots within ONE multiworld; two
        #     slots share a seed_name, so seed alone misses it (the framework
        #     would resend slot A's locations_checked to slot B on Connected).
        # Both are known before that resend: self.auth is set by server_auth,
        # which the built-in RoomInfo handler awaits before our on_package runs.
        # The server address is deliberately NOT part of the identity: a host can
        # return the SAME room on a new port (archipelago.gg inactivity sleep),
        # so a port change is not a playthrough change. Wiping then would drop
        # locations_checked / pending_ap_outbound the mod can't re-assert while
        # the bridge stays up. The same-seed-value / same-slot / same-port case
        # (which seed+slot also can't see) is instead caught authoritatively by
        # the mod's NEWGAME signal when the fresh save starts.
        # A transient AP blip / same-slot reconnect leaves both unchanged, so the
        # durable state correctly survives it. CommonContext.reset_server_state
        # is NOT the right hook. It runs on every disconnect, which the durable
        # state must survive.
        self._last_seed_name: Optional[str] = None
        self._last_auth: Optional[str] = None
        # Open castle Great Hall key config as the "GOALCFG c,s,l,d,q,mask"
        # payload, or None for vanilla / not-yet-received. Parsed from slot_data
        # on Connected; pushed to the mod on every game HELLO (sticky +
        # idempotent mod-side, so a fresh game launch / reconnect re-arms it).
        self.open_castle_goalcfg: Optional[str] = None
        # Sphere-ordered spell / key / card item names for the /hint command,
        # from slot_data on Connected. Empty when the seed omits it.
        self.hint_order: dict[str, list[str]] = {}
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
        # When true the seed put the Running logic flag in logic, so the mod
        # makes shift-to-run free (no bean drain, no >0-bean gate) to keep that
        # assumption sound. Parsed from slot_data on Connected, re-sent
        # RUNNING_LOGIC <0|1> on every HELLO.
        self.allow_running_logic: bool = False
        # When true, the mod swaps/injects bean-container AP tokens per level.
        # Parsed from slot_data on Connected; re-sent CONTAINERSANITY <0|1> on HELLO.
        self.containersanity: bool = False
        # Per-seed sticky set of Tradersanity location ids the client has
        # already published a broadcast hint for, loaded from AP server Data
        # Storage on Connected and written back on each new hint so a
        # reconnect / client restart never re-broadcasts the same hint.
        self.vendor_hint_key: Optional[str] = None
        self.hinted_vendor_locs: set[int] = set()
        # Sound, music, and dialogue randomizers. Each is a client-side file patch
        # of the install (HPSounds.u for sound, Music/*.ogg for music, AllDialog.uax
        # for dialogue), applied on Connected and loaded by the game on next launch,
        # rather than IPC to the mod. Parsed from slot_data; off (key absent) for
        # seeds that did not enable it. The seed is the effective seed (a /reroll
        # override wins over the slot_data seed). Dialogue also carries a shuffle
        # mode ("within_actor" / "all_actors"); sound and music are plain on/off.
        self.audio_enabled: dict[str, bool] = {kind: False for kind in _AUDIO_KINDS}
        self.audio_seed: dict[str, Optional[int]] = {kind: None for kind in _AUDIO_KINDS}
        # Per-seed shuffle mode for the mode_aware kinds (sound: on / no_footsteps;
        # dialogue: within_actor / all_actors). None for music and for off kinds.
        self.audio_mode: dict[str, Optional[str]] = {kind: None for kind in _AUDIO_KINDS}
        # Auto-launch: the matching install's Game.exe is started after the audio
        # randomizers settle (or when there is nothing to patch), so the game never
        # boots while files are being rewritten. The task handle lets /play await an
        # in-flight patch before launching. The flag means "a game we launched is
        # live or still booting"; it is reset when the game disconnects from the
        # bridge, so the next AP (re)connect auto-launches again. A game already
        # bridged (game_writer live) suppresses the launch regardless, so a plain AP
        # reconnect with the game still running never spawns a duplicate.
        self._game_launched: bool = False
        self._audio_task: Optional[asyncio.Task] = None
        # True when slot_data game_mode == "open_castle". Drives the one-way
        # "MODE open_castle" IPC line (sticky + idempotent mod-side; resent
        # every game HELLO). A durable, authoritative open castle signal that
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
        # bOpenCastleMode, preserving that invariant).
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
        # TrapLink. Enabled per-slot via slot_data on Connected; the tag lives
        # on self.tags. A trap this slot receives is broadcast as a TrapLink
        # Bounce (from _forward_one) and inbound trap Bounces are applied to the
        # game. The Bounce `source` is this slot's name (the community TrapLink
        # convention), used to drop the server's echo of our own Bounce.
        self.trap_link_enabled: bool = False
        # The trap types this slot enabled (slot_data `trap_pool`). Inbound
        # TrapLink traps are constrained to this set so a trap the player turned
        # off is never forced on them. Empty means "no traps in my own pool";
        # inbound then falls back to all known traps (trap_link is opt-in).
        self.trap_pool: list[str] = []
        # DeathLink. Opt-in per-slot via slot_data on Connected; the tag
        # itself lives on self.tags (managed by update_death_link). Inbound
        # deaths are NOT queued for an offline game (you can't die when not
        # playing), so a death received then is stale and dropped. Loop
        # prevention is the deterministic mod-side suppression latch; this
        # timestamp amnesty is only race insurance for genuine simultaneity
        # (CommonContext.last_death_link is stamped by both send_death and
        # on_deathlink, so it tracks the last death in either direction).
        self.death_link_enabled: bool = False
        # Startup "Connected to host:port" toast. The effective AP server
        # address (scheme stripped, port defaulted), formatted on every
        # Connected from self.server_address, which server_loop has by then
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
        handler = {
            "RoomInfo": self._on_room_info,
            "Connected": self._on_connected,
            "RoomUpdate": self._on_room_update,
            "ReceivedItems": self._on_received_items,
            "Retrieved": self._on_retrieved,
            "LocationInfo": self._on_location_info,
            "Bounced": self._on_bounced,
        }.get(cmd)
        if handler is not None:
            handler(args)

    def _on_room_info(self, args: dict) -> None:
        new_seed = args.get("seed_name")
        # self.auth is the slot name we're (re)authenticating as; the
        # built-in RoomInfo handler awaits server_auth before this runs, so
        # it is set before the framework's Connected resend of
        # locations_checked.
        new_auth = self.auth
        seed_changed = bool(self._last_seed_name and new_seed
                            and new_seed != self._last_seed_name)
        slot_changed = bool(self._last_auth and new_auth
                            and new_auth != self._last_auth)
        if seed_changed or slot_changed:
            reasons = []
            if seed_changed:
                reasons.append(f"seed {self._last_seed_name!r} → {new_seed!r}")
            if slot_changed:
                reasons.append(f"slot {self._last_auth!r} → {new_auth!r}")
            self._reset_connection_state("; ".join(reasons))
        if new_seed:
            self._last_seed_name = new_seed
        if new_auth:
            self._last_auth = new_auth

    def _apply_bool_slot_flag(self, sd: dict, key: str, attr: str, command: str,
                              label: str, on_text: str = "enabled",
                              off_text: str = "disabled") -> bool:
        """Read a boolean slot-data flag, store it on attr, mirror it to the game
        as "<command> 0|1", and log the result. Returns the resolved flag."""
        flag = bool(sd.get(key))
        setattr(self, attr, flag)
        self._send_to_game(f"{command} {1 if flag else 0}")
        logger.info(f"{label} {on_text if flag else off_text}")
        return flag

    def _on_connected(self, args: dict) -> None:
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

        # Open-castle bean-room ledger. Independent of the item ledger;
        # replayed to the mod once its own Retrieved lands (and every HELLO).
        self.beanroom_key = f"HP2PC_AP_beanroom:{self.team}:{self.slot}"
        self.beanroom_loaded = False
        asyncio.create_task(self._send_or_queue_ap_msg(
            {"cmd": "Get", "keys": [self.beanroom_key]},
            label=f"Get bean room state {self.beanroom_key}",
        ))

        # Map-follow key for the tracker. Re-publish the last known level on
        # AP (re)connect: the game only resends LEVEL when the game↔client
        # bridge reopens, so an AP-only reconnect would otherwise leave the
        # stored value stale.
        self.level_key = f"HP2PC_AP_level:{self.team}:{self.slot}"
        if self.current_level:
            self._persist_level(self.current_level)

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

        # Sphere-ordered item names for /hint (see _cmd_hint). Empty when the
        # seed's slot_data omits it; the command says so and defers to !hint.
        self.hint_order = sd.get("hint_order") or {}

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
        self._apply_bool_slot_flag(sd, "skip_vendor_voices", "skip_vendor_voices",
                                   "SKIP_VENDOR_VOICES", "Skip vendor voices")
        self._apply_bool_slot_flag(sd, "enable_quidditch_upgrades", "quidditch_upgrades",
                                   "QUIDDITCH_UPGRADES", "Quidditch upgrades")
        self._apply_bool_slot_flag(sd, "allow_running_logic", "allow_running_logic",
                                   "RUNNING_LOGIC", "Running in logic",
                                   on_text="enabled (sprint is free)")
        self._apply_bool_slot_flag(sd, "containersanity", "containersanity",
                                   "CONTAINERSANITY", "Containersanity")
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

        # Sound, music, and dialogue randomizers. All patch files in the
        # install, so they run in one task that resolves the install once
        # (prompting the player at most once) and does the file work off the
        # event loop. Off seeds restore from the backup. Auto-launch is chained
        # after, so the game boots only once the files have settled.
        self._audio_task = asyncio.create_task(self._connect_audio_then_launch(sd))

        # RingLink. Re-roll the per-connection source UUID and
        # (re)register the tag on every Connected so a reconnect stays
        # routable for Bounced packets. Disable cleanly if a later seed
        # / reconnect turns it off.
        if sd.get("ring_link"):
            asyncio.create_task(self._enable_ring_link())
        else:
            asyncio.create_task(self._disable_ring_link())

        # TrapLink. (Re)register the tag on every Connected so a reconnect
        # stays routable for Bounced trap packets; disable cleanly if a
        # later seed / reconnect turns it off. trap_pool is the slot's
        # enabled trap types, used to constrain inbound traps.
        self.trap_pool = list(sd.get("trap_pool") or [])
        if sd.get("trap_link"):
            asyncio.create_task(self._enable_trap_link())
        else:
            asyncio.create_task(self._disable_trap_link())

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
        # that drops the connection, and CommonClient auto-resends
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
        # No custom outbound-check or goal re-send here: CommonContext
        # resends self.locations_checked and re-asserts self.finished_game
        # for us in its own Connected handling (and on a Sync mismatch).

    def _on_room_update(self, args: dict) -> None:
        # The server pushes a checked_locations delta whenever any client
        # (including ours via a different process) collects one of our
        # locations. CommonContext has already merged the delta into
        # self.checked_locations by the time on_package runs, so just
        # rebuild from scratch. The diff against self.checked_csv
        # suppresses no-op pushes.
        if "checked_locations" in args:
            self._rebuild_checked_csv()

    def _on_received_items(self, args: dict) -> None:
        base = args.get("index") or 0
        for offset, item in enumerate(args.get("items", [])):
            # Absolute index in this slot's cumulative ReceivedItems list.
            # The stable per-item key used by the durable ledger. AP resends
            # the full list (base 0) on every reconnect, so storing by index
            # is idempotent.
            idx = base + offset
            self.received_by_index[idx] = item
            # Only forward once the ledger is known; otherwise replay could
            # run against an unknown consumed-set and double-grant. The
            # Retrieved handler does the catch-up forward.
            if self.ledger_loaded:
                self._forward_one(idx, item)

    def _on_retrieved(self, args: dict) -> None:
        keys = args.get("keys") or {}
        if self.vendor_hint_key is not None and self.vendor_hint_key in keys:
            val = keys.get(self.vendor_hint_key)
            self.hinted_vendor_locs = set(int(x) for x in val) if val else set()
            logger.info(
                f"Tradersanity vendor-hint set loaded: "
                f"{len(self.hinted_vendor_locs)} already-hinted location(s)"
            )
        if self.beanroom_key is not None and self.beanroom_key in keys:
            val = keys.get(self.beanroom_key)
            self.beanroom_state = val if isinstance(val, str) else ""
            self.beanroom_loaded = True
            self._send_resync_beanroom()
            logger.info(f"Bean room state loaded ({len(self.beanroom_state)} chars)")
        if self.ledger_key is not None and self.ledger_key in keys:
            val = keys.get(self.ledger_key)
            server_set = set(val) if val else set()
            if self._ledger_client_authoritative:
                # A NEWGAME wipe this session made our set the source of
                # truth. Keep ours and overwrite the server so a stale
                # value (a wipe Set lost to a dying socket) can't resurrect
                # consumed indices and block the fresh playthrough's grants.
                if self.consumed_indices != server_set:
                    self._persist_ledger()
            else:
                # Normal load: union rather than replace. On a fresh client
                # session our set is empty, so this adopts the server value;
                # on an AP reconnect mid-session it preserves any index we
                # applied but whose persist Set was lost (silent socket
                # death), so an already-applied item is never re-granted.
                merged = self.consumed_indices | server_set
                self.consumed_indices = merged
                if merged != server_set:
                    # We hold indices the server was missing; write the
                    # union back so the stored ledger catches up.
                    self._persist_ledger()
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
            self._send_resync_cards()

    def _on_location_info(self, args: dict) -> None:
        # CommonContext's built-in handler has already populated
        # self.locations_info[loc] = NetworkItem for every scouted
        # location before on_package runs. Rebuild + push the table.
        self._rebuild_appearance_table()
        # Vendor hints: when hint-on-open is on, push the resolved item
        # name for each Tradersanity location to the mod so the in-trade
        # label reads the actual item, not the generic "Archipelago Item".
        self._send_vendor_hints_to_mod()

    def _on_bounced(self, args: dict) -> None:
        # One Bounced packet may carry RingLink and/or TrapLink tags; each
        # handler filters on its own tag, so dispatch to both.
        self._handle_ring_bounce(args)
        self._handle_traplink_bounce(args)

    def _handle_ring_bounce(self, args: dict) -> None:
        """Apply an inbound RingLink Bounce to the game's bean total.

        Inbound is NOT cached: if the game is offline the delta is
        dropped, bypassing _send_to_game's offline queue. Replaying stale
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
        # non-int source. A failed int() means it isn't ours, so apply it.
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
            logger.info("DeathLink: inbound within amnesty window, not forwarding")
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
            self._toast_to_game(cause if cause else f"DeathLink received from {source}", white=True)
        except Exception as e:
            logger.warning(f"DeathLink: failed to forward inbound, dropping: {e}")

    def on_print_json(self, args: dict) -> None:
        # Toast feedback for items WE send to other slots ("Sent X to Y").
        # AP server broadcasts an ItemSend PrintJSON for every cross-slot
        # delivery; we filter to ones where item.player == self.slot (we're
        # the sender). Skip if receiving == self.slot. That's our own item
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
                    sender_name = self.player_names.get(self.slot, "Harry")
                    location_name = ""
                    if item.location > 0:
                        location_name = self.location_names.lookup_in_slot(item.location, self.slot) or ""
                    segrecord = self._build_item_segrecord(
                        sender_name, True, item_name, item.flags,
                        receiver_name, False, location_name,
                    )
                    logger.info(
                        f"Sent item: {item_name} → {receiver_name} "
                        f"(slot {receiving_slot}) loc={location_name!r}"
                    )
                    self._send_to_game(f"SENT {segrecord}")
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
                        self._toast_to_game(f"{name} joined", white=True)
                    elif ptype == "Part":
                        self._toast_to_game(f"{name} left", white=True)
                    else:
                        self._toast_to_game(f"{name} finished!", white=True)
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
        # CommonContext has NO update_tags(). Mirror update_death_link
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

    def _trap_link_source(self) -> str:
        """Slot name used as the TrapLink Bounce `source` (the community
        TrapLink convention). Both the outbound broadcast and the inbound
        self-filter derive it the same way, so the server's echo of our own
        Bounce is dropped. Slot names are unique within a multiworld."""
        if self.slot is None:
            return ""
        return self.player_names.get(self.slot, str(self.slot))

    async def _enable_trap_link(self) -> None:
        # Register the TrapLink tag (mirrors _enable_ring_link). The tag must
        # persist on self.tags so a later reconnect's Connect already carries
        # it; a ConnectUpdate is only needed when adding it mid-session.
        self.trap_link_enabled = True
        newly_tagged = "TrapLink" not in self.tags
        self.tags = set(self.tags) | {"TrapLink"}
        if newly_tagged and self.server and not self.server.socket.closed:
            try:
                await self.send_msgs([{"cmd": "ConnectUpdate", "tags": self.tags}])
            except Exception as e:
                logger.exception(f"TrapLink: ConnectUpdate(tags) failed, inbound traps won't route: {e}")
                return
        logger.info(f"TrapLink enabled (source={self._trap_link_source()!r}); TrapLink tag registered")

    async def _disable_trap_link(self) -> None:
        # Clean teardown mirroring _disable_ring_link. No-op when never tagged
        # (the common trap_link-off case).
        was_enabled = self.trap_link_enabled
        self.trap_link_enabled = False
        if "TrapLink" not in self.tags:
            return
        self.tags = set(self.tags) - {"TrapLink"}
        if self.server and not self.server.socket.closed:
            try:
                await self.send_msgs([{"cmd": "ConnectUpdate", "tags": self.tags}])
            except Exception as e:
                logger.exception(f"TrapLink: ConnectUpdate(tags) untag failed: {e}")
                return
        if was_enabled:
            logger.info("TrapLink disabled for this slot; TrapLink tag removed")

    def _handle_traplink_bounce(self, args: dict) -> None:
        """Apply an inbound TrapLink Bounce to the game.

        Like inbound RingLink/DeathLink, NOT cached: if the game is offline the
        trap is dropped (you can't be trapped when not playing). The mod's grant
        drain still gates application on a playable Harry, so a trap arriving
        mid-cutscene waits for control to return."""
        if not self.trap_link_enabled:
            return
        if "TrapLink" not in (args.get("tags") or []):
            return
        data = args.get("data") or {}
        # Drop the server's echo of our own Bounce (stock AP echoes to sender).
        if data.get("source") == self._trap_link_source():
            return
        foreign_name = data.get("trap_name")
        # Constrain to the player's enabled traps so a trap they turned off is
        # never forced on them. Empty trap_pool (they generated no traps but
        # opted into TrapLink) falls back to all known traps. Apply the foreign
        # name directly only if it's in that candidate set; otherwise (a foreign
        # game's trap, a missing name, or a disabled HP2 trap) remap to a random
        # candidate so a linked player always feels something they allowed.
        candidates = sorted(t for t in TRAP_ITEM_NAMES
                            if not self.trap_pool or t in self.trap_pool)
        if not candidates:
            candidates = sorted(TRAP_ITEM_NAMES)
        if isinstance(foreign_name, str) and foreign_name in candidates:
            local_name = foreign_name
        else:
            local_name = random.choice(candidates)
        source = data.get("source")
        source_label = source if isinstance(source, str) and source else "another world"
        if self.game_writer is None or self.game_writer.is_closing():
            logger.info(f"TrapLink: dropping inbound {local_name!r} (game offline, not cached)")
            return
        try:
            self.game_writer.write(f"TRAPLINK {local_name}|{source_label}\n".encode("utf-8"))
            logger.info(f"TrapLink: inbound {foreign_name!r} from {source_label!r} → TRAPLINK {local_name}")
        except Exception as e:
            logger.warning(f"TrapLink: failed to forward inbound {local_name!r}, dropping: {e}")

    def _maybe_broadcast_traplink(self, item_name: str) -> None:
        """If this slot just received one of its own trap items, share it with
        every other TrapLink slot. Called from _forward_one, which fires exactly
        once per genuinely-new trap (reconnect replays are filtered by the
        consumed-index ledger), so this never double-broadcasts."""
        if not self.trap_link_enabled:
            return
        if item_name not in TRAP_ITEM_NAMES:
            return
        if not (self.server and self.slot is not None):
            return
        asyncio.create_task(self._send_traplink_bounce(item_name))

    async def _send_traplink_bounce(self, trap_name: str) -> None:
        try:
            await self.send_msgs([{
                "cmd": "Bounce",
                "tags": ["TrapLink"],
                "data": {"time": time.time(), "trap_name": trap_name,
                         "source": self._trap_link_source()},
            }])
            logger.info(f"TrapLink: outbound {trap_name} → Bounce")
        except Exception as e:
            logger.warning(f"TrapLink: send Bounce failed for {trap_name}: {e}")

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

    def _toast_to_game(self, text: str, white: bool = False) -> None:
        """Cosmetic-only TOAST: drop on the floor when the game is offline.
        Replaying a stale "X joined" or "Disconnected from AP server" toast
        the next time the game launches would be confusing. These are
        in-the-moment events, not durable state.

        `white` routes multiworld lifecycle events (joins, inbound DeathLink) to
        the mod's neutral-white style; the default yellow is HP2's system voice."""
        if self.game_writer is None or self.game_writer.is_closing():
            return
        verb = "TOASTW " if white else "TOAST "
        try:
            self.game_writer.write((verb + text + "\n").encode("utf-8"))
        except Exception as e:
            logger.warning(f"TOAST drop ({text!r}): write failed: {e}")

    async def _apply_audio_randomizers(self, sd: dict) -> "tuple[bool, Optional[str]]":
        """Apply or restore the sound, music, and dialogue file patches for this
        seed on the install matching its game mode. Resolves the install once
        (prompting the player at most once) and runs the file work in an executor.

        Returns (safe_to_launch, install). safe is True when the install files are
        settled (patched, already-applied, or nothing to do) so the game can boot,
        and False when a needed patch could not be written. install is the resolved
        folder, or None when it is unset and nothing forced a prompt."""
        try:
            open_castle = sd.get("game_mode") == "open_castle"
            sound_mode = sd.get("sound_mode")        # None / absent when off
            music_on = bool(sd.get("music_randomizer"))
            dialogue_mode = sd.get("dialogue_mode")  # None / absent when off
            self.audio_mode["sound"] = sound_mode
            self.audio_mode["dialogue"] = dialogue_mode
            self.audio_enabled["sound"] = bool(sound_mode)
            self.audio_enabled["music"] = music_on
            self.audio_enabled["dialogue"] = bool(dialogue_mode)
            self.audio_seed["sound"] = (
                self._effective_seed(sd, "sound", "sound_seed") if sound_mode else None)
            self.audio_seed["music"] = self._effective_seed(sd, "music", "music_seed") if music_on else None
            self.audio_seed["dialogue"] = (
                self._effective_seed(sd, "dialogue", "dialogue_seed") if dialogue_mode else None)
            any_on = bool(sound_mode) or music_on or bool(dialogue_mode)

            install = _hp2_install_path(open_castle)
            valid = bool(install) and os.path.exists(sound_patch.package_path(install))
            logger.info(
                f"Audio randomizer: sound={sound_mode or 'off'} music={music_on} "
                f"dialogue={dialogue_mode or 'off'} "
                f"mode={'open_castle' if open_castle else 'vanilla'} "
                f"install={install!r} valid={valid}"
            )
            if not any_on:
                # No files to touch, so the game is safe to boot now. The launcher
                # resolves (and prompts once for) the folder itself if it is unset.
                ui_logger.info("All audio randomizers are off for this seed; leaving audio as-is.")
                return True, install

            if not valid:
                install = await self._prompt_install_folder(open_castle)
                valid = bool(install)
            if not valid:
                # A randomizer is on but the install is unknown, so nothing was
                # patched and the launcher has no folder either. Not safe to boot.
                return False, None

            loop = asyncio.get_event_loop()
            ok = True
            for kind in _AUDIO_KINDS:
                if not await self._patch_one(loop, kind, self.audio_enabled[kind], install):
                    ok = False
            return ok, install
        except Exception:
            ui_logger.exception("Audio randomizer task crashed")
            return False, None

    def _effective_seed(self, sd: dict, kind: str, key: str) -> int:
        """slot_data seed for this kind, unless a /reroll override is saved."""
        base = int(sd.get(key) or 0)
        override = _get_reroll(kind, self._reroll_key())
        return override if override is not None else base

    async def _patch_one(self, loop, kind: str, enabled: bool, install: str) -> bool:
        """Apply or restore one randomizer's files. Returns True when the files are
        settled (written, already-current, or nothing to do) and False when the
        write could not complete, so the caller can hold back the auto-launch."""
        spec = _AUDIO_KINDS[kind]
        try:
            if enabled:
                seed = self.audio_seed[kind]
                if spec.mode_aware:
                    fut = loop.run_in_executor(
                        None, spec.patch.apply_patch, install, seed, self.audio_mode[kind])
                else:
                    fut = loop.run_in_executor(None, spec.patch.apply_patch, install, seed)
            elif spec.present(install):
                fut = loop.run_in_executor(None, spec.patch.restore_original, install)
            else:
                return True
            # Bound the wait: a denied Program Files write can hang the file op
            # instead of failing fast, which previously left no message at all.
            result = await asyncio.wait_for(fut, timeout=20)
        except asyncio.TimeoutError:
            ui_logger.error(
                f"{spec.noun}: writing the install did not finish (the write looks blocked). "
                f"If the install is under Program Files, close Harry Potter and run the "
                f"Archipelago launcher as administrator, then reconnect."
            )
            return False
        except _PATCH_ERRORS as exc:
            ui_logger.error(f"{spec.noun}: {exc}")
            return False
        self._announce_patch(kind, enabled, result)
        return True

    async def _connect_audio_then_launch(self, sd: dict) -> None:
        """Run the audio randomizers, then auto-launch the game once they have
        settled. Chaining the two keeps the game from booting while the install
        files are still being rewritten, and lets the launch reuse the folder the
        audio step already resolved, so the player is never asked twice."""
        safe, install = await self._apply_audio_randomizers(sd)
        if not _auto_launch_enabled():
            return
        # Launch on every AP (re)connect, not just the first of the session, so a
        # reconnect after the game closed re-opens it. Suppress only when a game is
        # already up: game_writer live means a game (ours or one the player started
        # by hand) is bridged; _game_launched means our own launch is still booting
        # and has not bridged yet. Either way a second Game.exe would be a duplicate.
        game_bridged = self.game_writer is not None and not self.game_writer.is_closing()
        if self._game_launched or game_bridged:
            return
        if not safe:
            ui_logger.warning(
                "Not auto-launching: the install is not ready (a randomizer could not "
                "be applied, or its folder is unset). Fix it above, then type /play."
            )
            return
        await self._auto_launch(install)

    async def _resolve_launch_folder(self) -> Optional[str]:
        """The install folder to launch for this seed's mode: the configured one if
        valid, else a one-time folder picker. None if it cannot be resolved."""
        install = _hp2_install_path(self.is_open_castle)
        if install and os.path.exists(sound_patch.package_path(install)):
            return install
        return await self._prompt_install_folder(self.is_open_castle)

    async def _auto_launch(self, install_hint: Optional[str]) -> None:
        """Launch Game.exe for this seed's mode. Reuses the folder the audio step
        resolved when it is valid, else resolves (and prompts once for) it."""
        if install_hint and os.path.exists(sound_patch.package_path(install_hint)):
            install = install_hint
        else:
            install = await self._resolve_launch_folder()
        if install:
            self._launch_game(install)

    async def _launch_game_manual(self) -> None:
        """Back the /play command. Waits for any in-flight randomizer patch so a
        manual launch never races a file write either, then launches regardless of
        the once-per-session guard."""
        if self._audio_task is not None and not self._audio_task.done():
            ui_logger.info("Waiting for the audio randomizers to finish before launching.")
            try:
                await self._audio_task
            except Exception:
                pass
        install = await self._resolve_launch_folder()
        if install:
            self._launch_game(install)

    def _launch_game(self, install: str) -> None:
        """Start Game.exe from the install's system folder. The UE1 engine needs
        its working directory to be that system folder, so the process is spawned
        with cwd there. Marks a launch live so auto-launch will not also fire while
        this game is booting or running; the bridge disconnect re-arms it."""
        system_dir = os.path.join(install, "system")
        exe = os.path.join(system_dir, "Game.exe")
        if not os.path.exists(exe):
            ui_logger.error(
                f"Cannot launch: '{exe}' not found. Check the install folder for this "
                f"seed's mode in host.yaml."
            )
            return
        mode = "open castle" if self.is_open_castle else "vanilla"
        try:
            subprocess.Popen([exe], cwd=system_dir)
        except OSError as exc:
            ui_logger.error(f"Could not launch Harry Potter ({mode}): {exc}")
            return
        self._game_launched = True
        ui_logger.info(f"Launching Harry Potter ({mode}).")

    async def _prompt_install_folder(self, open_castle: bool) -> Optional[str]:
        """Pop a folder picker for the seed's game mode and persist the choice to
        host.yaml, so the player picks their install once. The client needs it to
        launch the game and to apply any randomizers. Returns the chosen folder
        (which contains system/Game.exe and system/HPSounds.u) or None if cancelled
        / no GUI."""
        mode = "open castle" if open_castle else "vanilla"
        field = "open_castle_install_folder" if open_castle else "vanilla_install_folder"
        ui_logger.info(
            f"First connect: pick your Harry Potter 2 {mode} install folder so the "
            f"client can launch the game (and apply any randomizers). It is the folder "
            f"that contains the 'system' folder with Game.exe. Saved to host.yaml, so "
            f"you are asked only once per mode."
        )
        try:
            from Utils import open_directory
        except Exception:
            ui_logger.warning(
                f"The client needs your {mode} install folder, but no folder picker is "
                f"available here. Set 'harry_potter_2_pc_options' -> '{field}' in "
                f"host.yaml."
            )
            return None
        title = f"Select your Harry Potter 2 {mode} install folder (contains system\\Game.exe)"
        loop = asyncio.get_event_loop()
        chosen = await loop.run_in_executor(None, open_directory, title)
        if not chosen:
            ui_logger.warning(
                f"No {mode} install folder chosen. Reconnect to pick it, or set "
                f"'harry_potter_2_pc_options' -> '{field}' in host.yaml."
            )
            return None
        if not os.path.exists(sound_patch.package_path(chosen)):
            ui_logger.warning(
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
            ui_logger.info(f"Saved {field} to host.yaml: {path}")
        except Exception as exc:
            ui_logger.warning(
                f"Picked '{path}' but could not save it to host.yaml ({exc}); set "
                f"'{field}' manually to avoid being asked again."
            )

    def _announce_patch(self, kind: str, enabled: bool, result: str) -> None:
        # A live game already loaded the old files, so a change needs one restart;
        # if the game is not up yet, the next launch picks it up with no restart.
        spec = _AUDIO_KINDS[kind]
        noun, thing = spec.noun, spec.thing
        seed = self.audio_seed[kind]
        if enabled and result == "patched":
            if self.game_writer is not None:
                self._toast_to_game(f"{noun} applied. Restart to hear it.")
                ui_logger.info(f"{noun} applied (seed {seed}). Restart Harry Potter to hear it.")
            else:
                ui_logger.info(f"{noun} applied (seed {seed}); it loads when you launch Harry Potter.")
        elif enabled and result == "unchanged":
            ui_logger.info(f"{noun}: seed {seed} is already applied to this install; no change.")
        elif not enabled and result == "restored":
            if self.game_writer is not None:
                self._toast_to_game(f"Original {thing} restored. Restart to apply.")
                ui_logger.info(f"Original {thing} restored. Restart Harry Potter.")
            else:
                ui_logger.info(f"Original {thing} restored; they load on next launch.")

    def _reroll_key(self) -> str:
        """Per-AP-seed key for a /reroll override."""
        return f"{self._last_seed_name}:{self.slot}"

    async def _reroll(self, kind: str, install: str) -> None:
        """Re-patch this kind with a fresh seed and remember it for this AP seed so
        the reshuffle survives reconnects. Dialogue keeps the seed's shuffle mode.
        Runs the file work in an executor."""
        spec = _AUDIO_KINDS[kind]
        new_seed = random.randint(0, 2**31 - 1)
        loop = asyncio.get_event_loop()
        try:
            if spec.mode_aware:
                result = await loop.run_in_executor(
                    None, spec.patch.apply_patch, install, new_seed, self.audio_mode[kind])
            else:
                result = await loop.run_in_executor(None, spec.patch.apply_patch, install, new_seed)
        except _PATCH_ERRORS as exc:
            ui_logger.error(f"{spec.noun} reroll: {exc}")
            return
        self.audio_seed[kind] = new_seed
        _save_reroll(kind, self._reroll_key(), new_seed)
        thing = spec.thing.capitalize()
        if result == "patched":
            self._toast_to_game(f"{thing} reshuffled. Restart to hear the new set.")
            ui_logger.info(f"{thing} reshuffled. Restart Harry Potter to hear the new set.")
        else:
            ui_logger.info(f"Reshuffle landed on the same set; run {spec.reroll_cmd} again.")

    async def handle_game_connection(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        logger.info(f"Game connected from {peer}")
        # Surface the game link in the client window too (ui_logger = "Client"
        # logger). logger above is HP2Client, which is file-only.
        ui_logger.info("The Harry Potter 2 game connected to this client. It can now send and receive items.")
        self.game_writer = writer
        # Fresh game session. Clear the per-session sent-index guard so the
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
                # Outbound frames are newline-led (see the mod's SendLine), so a
                # blank line between messages is expected framing, not content.
                if not line:
                    continue
                logger.info(f"[game→client] {line}")
                await self._handle_game_line(line)
        except (ConnectionResetError, ConnectionAbortedError):
            # Normal on Windows when the game window closes. The OS resets
            # the socket without a clean FIN. No need to log a stack trace.
            pass
        finally:
            logger.info(f"Game disconnected ({peer})")
            ui_logger.info("The Harry Potter 2 game disconnected from this client. Relaunch the game to reconnect.")
            # Only clear game_writer if it's still OUR writer. On Windows
            # ProactorEventLoop the previous game's readline can wake up
            # *after* a new game has already connected and replaced
            # self.game_writer; clobbering it here would strand the new
            # connection until client restart.
            if self.game_writer is writer:
                self.game_writer = None
                # The game we launched (or the player started) is gone. Re-arm
                # auto-launch so the next AP (re)connect opens it again. Guarded by
                # the writer-identity check so a stale late-waking old game can't
                # re-arm over a newer game that already replaced game_writer.
                self._game_launched = False
            try:
                writer.close()
            except Exception:
                pass
            # Skip wait_closed() entirely. On Windows ProactorEventLoop, an
            # already-reset socket raises ConnectionResetError from the loop's
            # internal _loop_reading task, which asyncio surfaces as
            # "Unhandled exception in client_connected_cb" regardless of any
            # try/except we wrap around it. close() alone is sufficient for
            # cleanup; the OS reaps the socket either way.

    async def _handle_game_line(self, line: str) -> None:
        # Game lines are "COMMAND" or "COMMAND <args>"; dispatch on the first word.
        # The command words are distinct (CHECK vs CHECK_SPELL/_KEYITEM/_LOCID),
        # so the first token routes unambiguously.
        handler = {
            "APPLIED": self._on_applied,
            "BEANSTATE_BEGIN": self._on_beanstate_begin,
            "BEANSTATE_END": self._on_beanstate_end,
            "BEANSTATE": self._on_beanstate,
            "DRAIN_ROLLBACK": self._on_drain_rollback,
            "NEWGAME": self._on_newgame,
            "HELLO": self._on_hello,
            "GOAL_COMPLETE": self._on_goal_complete,
            "RINGOUT": self._on_ringout,
            "DEATH": self._on_death,
            "LEVEL": self._on_level,
            "SAY": self._on_say,
            "CHECK_SPELL": self._on_check_spell,
            "CHECK_KEYITEM": self._on_check_keyitem,
            "CHECKEDOUT": self._on_checkedout,
            "CHECK_LOCID": self._on_check_locid,
            "VENDOR_OPENED": self._on_vendor_opened,
            "CHECK": self._on_check,
        }.get(line.split(" ", 1)[0])
        if handler is not None:
            await handler(line)

    async def _on_applied(self, line: str) -> None:
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

    async def _on_beanstate_begin(self, line: str) -> None:
        # Start of a chunked bean-room ledger snapshot (sent on leaving the
        # room). Reset the accumulator; the BEANSTATE chunk lines that follow
        # are concatenated verbatim and committed on BEANSTATE_END.
        self._beanstate_accum = ""
        return

    async def _on_beanstate(self, line: str) -> None:
        # One chunk of the current snapshot. Append verbatim: the mod splits on
        # raw character count, so byte-for-byte concatenation reproduces the
        # original payload. A lone chunk outside a BEGIN/END pair (never sent by
        # the current mod) is harmless: it only lands on END.
        self._beanstate_accum += line[len("BEANSTATE "):]
        return

    async def _on_beanstate_end(self, line: str) -> None:
        # Snapshot complete. Commit and persist to AP storage so the room's
        # collected / opened state survives a game restart. A snapshot whose END
        # never arrives (mid-send disconnect) leaves beanroom_state untouched, so
        # a partial ledger is never persisted.
        self.beanroom_state = self._beanstate_accum
        self._persist_beanroom()
        return

    async def _on_drain_rollback(self, line: str) -> None:
        # Mod completed a death-revert: any item between the last save and
        # the death was un-applied by LoadGame 0, and its APPLIED ack was
        # buffered but never flushed. Anything in sent_this_session that
        # isn't durably consumed is exactly that set. Drop it from the
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

    async def _on_newgame(self, line: str) -> None:
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
        # Our wiped set is now authoritative over the server's stored value:
        # a reconnect must not merge a stale pre-wipe ledger back in (see the
        # Retrieved handler). A fresh game also hasn't goaled.
        self._ledger_client_authoritative = True
        self.finished_game = False
        # A fresh save has checked nothing. Drop the local check cache so the
        # framework's next Connected resend can't replay a prior
        # playthrough's locations. The backstop for two rooms the connect-
        # time identity can't tell apart (same seed value → same seed_name,
        # same slot name, same host:port). The new game's genuine checks
        # repopulate this via CHECK / CHECKEDOUT.
        self.locations_checked = set()
        self._persist_ledger()
        # Fresh playthrough: clear the persisted bean-room ledger so its room
        # starts full (the mod wipes its class-default copy on NEWGAME too).
        self.beanroom_state = ""
        self._beanstate_accum = ""
        self._persist_beanroom()
        self._send_resync_spells()
        self._forward_all_received()
        return

    async def _on_hello(self, line: str) -> None:
        # Game (re)connected. Re-forward every received item not yet
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
        # Re-arm running-in-logic so a fresh launch / reconnect keeps the
        # sprint free when the seed put Running in logic.
        self._send_to_game(f"RUNNING_LOGIC {1 if self.allow_running_logic else 0}")
        self._send_to_game(f"CONTAINERSANITY {1 if self.containersanity else 0}")
        # Re-push Tradersanity vendor hint item names to the mod. Sticky +
        # idempotent mod-side (cached per-slot on APCardWatcher), so
        # resending every HELLO covers fresh launches / reconnects.
        self._send_vendor_hints_to_mod()
        # Re-arm the Tradersanity per-vendor price factors. Sticky +
        # idempotent mod-side (writes a class-default byte table). Only
        # sent when Tradersanity is on. When off the mod never reads the
        # table, and an off seed should not be carrying stale factors.
        if self.tradersanity_prices_csv:
            self._send_to_game("TRADERPRICES " + self.tradersanity_prices_csv)
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
        # so the empty-string "no checks yet" payload still re-arms. The
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
            self._send_resync_cards()
        # Bean-room ledger is independent of the item ledger; gate on its own
        # load flag so a fresh game launch / reconnect re-asserts it.
        if self.beanroom_loaded:
            self._send_resync_beanroom()
        return

    async def _on_goal_complete(self, line: str) -> None:
        # The mod replays GOAL_COMPLETE on every bridge connect while it
        # holds the end-game latch, so this can re-fire; finished_game
        # dedupes it. Setting finished_game also arms CommonContext to
        # re-assert CLIENT_GOAL on every AP reconnect, covering a goal
        # reached while AP was unreachable.
        if self.finished_game:
            return
        self.finished_game = True
        await self._send_or_queue_ap_msg(
            {"cmd": "StatusUpdate", "status": ClientStatus.CLIENT_GOAL},
            label="ClientStatus.CLIENT_GOAL (slot complete)",
        )
        return

    async def _on_ringout(self, line: str) -> None:
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
        # delta. Beans are filler; the baseline has already moved, so it
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

    async def _on_death(self, line: str) -> None:
        # Harry entered stateDead. Broadcast a DeathLink Bounce only while
        # tagged (death_link on) and outside the amnesty window. The mod
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
        # player name (slot known here, the offline guard above ran), so
        # receiving games show which AP slot died, not the in-game avatar.
        me = self.player_names.get(self.slot, "Harry")
        cause = f"{me} got avada kadavra'd"
        logger.info(f"DeathLink: outbound death → Bounce ({cause})")
        await self.send_death(cause)
        self._toast_to_game("DeathLink sent")
        return

    async def _on_level(self, line: str) -> None:
        # Current map the player entered. Mirror it to AP Data Storage so
        # the PopTracker can follow the player to the matching map tab.
        level = line[len("LEVEL "):].strip()
        if level:
            self.current_level = level
            self._persist_level(level)
        return

    async def _on_say(self, line: str) -> None:
        # Cosmetic only: a ~1/100 spell-cast roll fired mod-side. Post a
        # random flavor line to multiworld chat. No dedupe / no location
        # semantics. Purely a gag.
        await self._handle_spell_say(line[len("SAY "):].strip())
        return

    async def _on_check_spell(self, line: str) -> None:
        spell_name = line[len("CHECK_SPELL "):].strip()
        await self._send_named_location_check(
            kind="spell",
            game_name=spell_name,
            name_to_location=SPELL_TO_LOCATION_NAME,
        )
        return

    async def _on_check_keyitem(self, line: str) -> None:
        key_item_name = line[len("CHECK_KEYITEM "):].strip()
        await self._send_named_location_check(
            kind="key item",
            game_name=key_item_name,
            name_to_location=KEYITEM_TO_LOCATION_NAME,
        )
        return

    async def _on_checkedout(self, line: str) -> None:
        await self._handle_checked_out(line[len("CHECKEDOUT "):].strip())
        return

    async def _on_check_locid(self, line: str) -> None:
        try:
            location_id = int(line[len("CHECK_LOCID "):].strip())
        except ValueError:
            logger.warning(f"Unparseable CHECK_LOCID: {line!r}")
            return
        if location_id in self.locations_checked:
            return
        self.locations_checked.add(location_id)
        await self._send_or_queue_ap_msg(
            {"cmd": "LocationChecks", "locations": [location_id]},
            label=f"LocationChecks for AP location id {location_id} (raw CHECK_LOCID)",
        )
        return

    async def _on_vendor_opened(self, line: str) -> None:
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

    async def _on_check(self, line: str) -> None:
        try:
            check_id = int(line[len("CHECK "):].strip())
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
        if location_id in self.locations_checked:
            return
        self.locations_checked.add(location_id)
        await self._send_or_queue_ap_msg(
            {"cmd": "LocationChecks", "locations": [location_id]},
            label=f"LocationChecks for {location_name} (id={location_id}, game CHECK {check_id})",
        )

    async def _send_named_location_check(self, kind: str, game_name: str, name_to_location: dict[str, str]) -> None:
        location_name = name_to_location.get(game_name)
        if location_name is None:
            logger.info(f"Game {kind} {game_name!r} has no AP location mapping "
                        f"(likely starter / non-progression); skipping")
            return
        location_id = LOCATION_NAME_TO_ID.get(location_name)
        if location_id is None:
            logger.warning(f"{kind.capitalize()} location {location_name!r} has no AP id; dropping")
            return
        if location_id in self.locations_checked:
            return
        self.locations_checked.add(location_id)
        await self._send_or_queue_ap_msg(
            {"cmd": "LocationChecks", "locations": [location_id]},
            label=f"LocationChecks for {location_name} (id={location_id}, {kind} {game_name!r})",
        )

    def _random_other_player(self) -> Optional[str]:
        """A random real player that isn't us, or None if there is no such
        player resolvable. Excludes our own slot, the Server pseudo-slot
        (slot 0), and group / item-link pseudo-slots (SlotType.group). When
        AP is offline self.slot is None. We can't reliably tell ourselves
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
        """A ~1/100 spell-cast roll fired SAY mod-side. Post a random flavor
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

    async def _handle_checked_out(self, csv: str) -> None:
        """Mod replay of its locally-collected checks (the inverse of the
        CHECKED resync), sent on every bridge connect. Records each id into
        self.locations_checked, which CommonContext resends to the server on
        every Connected, so a check fired while the client wasn't bridged
        (client launched after the pickup, or client restarted) still reaches
        AP. Also pushes the missing ones live if AP is up now. Unparseable
        tokens are skipped."""
        new_ids: set[int] = set()
        for tok in csv.split(","):
            tok = tok.strip()
            if not tok:
                continue
            try:
                new_ids.add(int(tok))
            except ValueError:
                logger.warning(f"CHECKEDOUT: unparseable id {tok!r}, skipping")
        new_ids -= self.locations_checked
        if not new_ids:
            return
        self.locations_checked |= new_ids
        logger.info(f"CHECKEDOUT: recorded {len(new_ids)} mod-side check(s)")
        # Live send of the ones the server is missing; the framework's Connected
        # resend is the safety net if AP is offline right now.
        to_send = sorted(new_ids - set(self.checked_locations))
        if to_send:
            await self._send_or_queue_ap_msg(
                {"cmd": "LocationChecks", "locations": to_send},
                label=f"LocationChecks ({len(to_send)} via CHECKEDOUT replay)",
            )

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
        reconnect). want_reply=False. Single writer, no read-back needed."""
        if self.ledger_key is None:
            return
        asyncio.create_task(self._send_or_queue_ap_msg(
            {"cmd": "Set", "key": self.ledger_key, "default": [],
             "want_reply": False,
             "operations": [{"operation": "replace",
                             "value": sorted(self.consumed_indices)}]},
            label=f"persist durable ledger ({len(self.consumed_indices)} index(es))",
        ))

    def _persist_level(self, level: str) -> None:
        """Mirror the player's current map to AP server Data Storage so the
        tracker can follow along (it reads level_key on connect and subscribes
        for changes). Offline-safe queue + replace semantics, want_reply=False.
        Single writer, latest value wins."""
        if self.level_key is None:
            return
        asyncio.create_task(self._send_or_queue_ap_msg(
            {"cmd": "Set", "key": self.level_key, "default": "",
             "want_reply": False,
             "operations": [{"operation": "replace", "value": level}]},
            label=f"persist current level ({level})",
        ))

    def _persist_beanroom(self) -> None:
        """Write the open-castle bean-room ledger back to AP Data Storage so the
        room's collected / opened state survives a game restart. Offline-safe
        queue + replace semantics, want_reply=False. Single writer, latest wins."""
        if self.beanroom_key is None:
            return
        asyncio.create_task(self._send_or_queue_ap_msg(
            {"cmd": "Set", "key": self.beanroom_key, "default": "",
             "want_reply": False,
             "operations": [{"operation": "replace", "value": self.beanroom_state}]},
            label="persist bean room state",
        ))

    def _send_resync_beanroom(self) -> None:
        """Push the persisted bean-room ledger to the mod, which merges dispensers /
        floor (set, never clear) and restores dropped-bean positions on a cold
        load. Sent on the bean-room Retrieved and every game HELLO. _send_to_game
        queues if the game bridge is down."""
        if self.beanroom_state:
            self._send_to_game("RESYNC_BEANROOM " + self.beanroom_state)
        else:
            self._send_to_game("RESYNC_BEANROOM")

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

    def _granted_names_in(self, name_set: "frozenset[str]") -> set[str]:
        """Every item name this slot has ever received from AP that is in
        name_set. AP replays the full ReceivedItems on every Connected, so
        received_by_index is authoritative without a parallel Data Storage
        record. Backs the granted_* membership properties below."""
        return {
            name
            for item in self.received_by_index.values()
            for name in (self.item_names.lookup_in_game(item.item, GAME_NAME),)
            if name in name_set
        }

    @property
    def granted_spell_names(self) -> set[str]:
        """Spell item names received from AP. Read by `_send_resync_spells`."""
        return self._granted_names_in(SPELL_ITEM_NAMES_SET)

    @property
    def granted_blocker_key_names(self) -> set[str]:
        """Bookcase-blocker keys received from AP. Read by
        `_send_resync_blocker_keys` on every Connected + game HELLO."""
        return self._granted_names_in(BLOCKER_KEY_NAMES_SET)

    @property
    def granted_card_class_names(self) -> set[str]:
        """Wizard-card UScript class names (the GRANT-payload form, via
        ITEM_NAME_TO_CARD_CLASS) this slot has ever received from AP, derived
        from received_by_index the same way as `granted_spell_names`. Read by
        `_send_resync_cards` on every Connected + game HELLO. Cards have no other
        durable record (the mod's folio is the only store and the .usa cannot
        persist mod state), so this is the source of truth for re-asserting
        CardOwner_Harry on a card the folio dropped."""
        return {
            ucls
            for item in self.received_by_index.values()
            for ucls in (ITEM_NAME_TO_CARD_CLASS.get(
                self.item_names.lookup_in_game(item.item, GAME_NAME)),)
            if ucls
        }

    @property
    def granted_key_item_names(self) -> set[str]:
        """Potion-ingredient key items (Boomslang / Bicorn / BitOGoyle) received
        from AP. Always empty today (these names are not items), but the
        membership test mirrors the spell / blocker-key pattern so a future
        randomization picks up save-load survivability without further wiring."""
        return self._granted_names_in(KEY_ITEM_NAMES_SET)

    def _send_resync(self, command: str, names: set[str]) -> None:
        """Push a derived ledger to the mod as a single sticky + idempotent
        RESYNC line. The bare command (no trailing space) is the empty-list form
        the mod expects (APIPCActor.HandleLine has a separate exact-match
        branch); a non-empty ledger rides as "<command> a,b,c"."""
        csv = ",".join(sorted(names))
        self._send_to_game(f"{command} {csv}" if csv else command)

    def _send_resync_spells(self) -> None:
        """Push the spell ledger. Sent on every Connected (Retrieved) and game
        HELLO. Empty payload still opens the mod's wipe gate, so a slot with no
        spells yet correctly reverts vanilla-engine F/L/A on the first tick."""
        self._send_resync("RESYNC_SPELLS", self.granted_spell_names)

    def _send_resync_blocker_keys(self) -> None:
        """Push the bookcase-blocker-key ledger. The mod re-stamps
        default.APGrantedBlockerKey[] AND destroys any matching live blocker, so
        a cold load that wiped the class-defaults isn't soft-locked by the
        consumed-indices ledger blocking GRANT replay. Covers both modes: open
        castle (per-key blocker) and vanilla (cumulative chain plus standalone
        Duelling/Quidditch)."""
        self._send_resync("RESYNC_BLOCKERKEYS", self.granted_blocker_key_names)

    def _send_resync_key_items(self) -> None:
        """Push the potion-key-item ledger. Always empty today (none of the three
        names are items); wired up so future randomization of any of them
        inherits the spell / blocker-key save-load survivability."""
        self._send_resync("RESYNC_KEYITEMS", self.granted_key_item_names)

    def _send_resync_cards(self) -> None:
        """Push the wizard-card ledger. The mod re-stamps default.APGrantedCard[]
        AND re-asserts CardOwner_Harry for any received card the folio is missing,
        so a save-load / death-reload that dropped one isn't permanent. The
        consumed-indices ledger would otherwise block GRANT replay, the cause of
        the gold-card-room "tracker says enterable but folio is short" reports."""
        self._send_resync("RESYNC_CARDS", self.granted_card_class_names)

    @staticmethod
    def _item_role(flags: int, own_item_name: str = "") -> str:
        """AP classification flag -> toast role letter. Bit-priority: progression
        beats trap beats useful beats filler, so a progression+useful item reads
        as progression rather than falling through to filler.

        own_item_name (set only for items WE receive) recovers the role for
        cheat-sent items: server /send and the !getitem console build a
        NetworkItem with no flags (default 0), so any of our items would
        otherwise read as filler. ItemClassification shares the network flag bits
        (progression=1, useful=2, trap=4), so the looked-up classification feeds
        the same bit-priority below. Foreign items we route onward keep this
        empty and rely solely on flags, since the name table is HP2's only.
        Open castle promotes cards to progression at create_item time, which a
        real receipt reflects in its flags; a cheat-sent card recovers only the
        static useful here, an accepted cosmetic gap on the cheat path."""
        if not (flags & ITEM_FLAG_ANY_CLASSIFIED) and own_item_name in ITEM_CLASSIFICATIONS:
            flags = int(ITEM_CLASSIFICATIONS[own_item_name])
        if flags & ITEM_FLAG_PROGRESSION:
            return "g"
        if flags & ITEM_FLAG_TRAP:
            return "t"
        if flags & ITEM_FLAG_USEFUL:
            return "u"
        return "f"

    def _build_item_segrecord(
        self, sender_name, sender_is_self, item_name, flags,
        receiver_name, receiver_is_self, location_name,
    ) -> str:
        """Colourised toast segment record for an item move, mirroring the
        AP-standard "X sent Y to Z" / "X found their Y" phrasing. Segments are
        `<roleChar><text>` joined by \\x1e; the mod parses them into its segment
        pool. Roles: s=our slot, o=other slot, g/u/t/f=item by flag, l=location,
        w=white connective, n=line break. The location, when known, goes on a
        second line in parentheses."""
        # receiver_is_self => this is an item WE receive, so it is one of HP2's
        # own items: pass its name so a cheat-sent (flags=0) trap still colours
        # as a trap. The SENT path (foreign item) leaves the name out.
        item_seg = self._item_role(flags, item_name if receiver_is_self else "") + item_name
        if sender_is_self and receiver_is_self:
            segs = ["s" + sender_name, "w found their ", item_seg]
        else:
            segs = [
                ("s" if sender_is_self else "o") + sender_name,
                "w sent ",
                item_seg,
                "w to ",
                ("s" if receiver_is_self else "o") + receiver_name,
            ]
        if location_name:
            segs += ["n", "w(", "l" + location_name, "w)"]
        return "\x1e".join(segs)

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
        sender_is_self = item.player == self.slot
        receiver_name = self.player_names.get(self.slot, "Harry")
        location_name = ""
        if item.location > 0:
            location_name = self.location_names.lookup_in_slot(item.location, item.player) or ""
        segrecord = self._build_item_segrecord(
            sender_name, sender_is_self, item_name, item.flags,
            receiver_name, True, location_name,
        )
        logger.info(
            f"Forwarding item idx={idx} {item_name} (id={item.item}) from "
            f"{sender_name} (self={sender_is_self}) loc={location_name!r}"
        )
        self._send_to_game(f"GRANT {idx} {payload}\x1f{segrecord}")
        # TrapLink: a trap landing on this slot is shared with every other
        # TrapLink slot. _forward_one fires once per genuinely-new trap, so the
        # broadcast is correctly deduped (a no-op unless trap_link is on).
        self._maybe_broadcast_traplink(item_name)

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
            if (ni.flags & ITEM_FLAG_PROGRESSION) or (ni.flags & ITEM_FLAG_TRAP):
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
        LocationChecked[] / NonCardLocationChecked[] on a fresh process.
        Those arrays are process-lifetime only. The intersect mirrors the
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
            tradersanity_ids.add(LOCATION_NAME_TO_ID["Castle Exterior - Nimbus 2001"])
            tradersanity_ids.add(LOCATION_NAME_TO_ID["Castle Exterior - Quidditch Armour"])
        for loc_id in tradersanity_ids:
            ni = self.locations_info.get(loc_id)
            if ni is None:
                continue
            item_name = self.item_names.lookup_in_slot(ni.item, ni.player)
            if not item_name:
                continue
            # "<slot>'s <item>" so the label reads as a possessive sentence
            # rather than just an item name in a vacuum. Makes the foreign
            # ownership obvious. For our own items we use the slot name too;
            # if it gets noisy we can branch on `ni.player == self.slot`
            # and drop the prefix.
            player_name = self.player_names.get(ni.player, f"player_{ni.player}")
            payload = f"{player_name}'s {item_name}"
            self._send_to_game(f"HINT {loc_id} {payload}")

    def _rebuild_appearance_table(self) -> None:
        """Recompute the per-location appearance payload from locations_info
        and push it to the mod if it changed. Only HP2 location ids appear in
        locations_info (we scout only our own). Codes of 0 are omitted. The
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

    def _reset_connection_state(self, reason: str) -> None:
        """Wipe per-slot state when the connection identity (seed or slot name)
        changes, so one slot's outbound checks / received items / goal never
        carry over to the next. Called from the RoomInfo handler before the
        framework's Connected handler resends self.locations_checked."""
        logger.info(
            f"Connection identity changed ({reason}); clearing prior-slot state "
            f"({len(self.pending_grants)} pending grant(s), "
            f"{len(self.pending_ap_outbound)} pending AP msg(s), "
            f"{len(self.locations_checked)} checked location(s), "
            f"finished_game={self.finished_game})"
        )
        self.pending_grants = []
        self.pending_ap_outbound = []
        # The new slot has its own location universe and its own completion;
        # drop the framework resend/goal state so we never replay slot A's
        # checks or goal to slot B.
        self.locations_checked = set()
        self.finished_game = False
        # Drop the prior slot's durable-ledger state; the new slot has its own
        # ledger_key (team:slot), so the next Connected recomputes it and
        # re-fetches its own consumed-index set from AP storage. Clearing
        # received_by_index also clears the spell ledger (it's a @property
        # derived from this dict).
        self.ledger_key = None
        self.consumed_indices = set()
        self._ledger_client_authoritative = False
        self.ledger_loaded = False
        self.received_by_index = {}
        self.sent_this_session = set()
        # #3: drop the prior slot's appearance table so the next Connected's
        # scout rebuilds it from scratch (item placement differs per slot).
        self.appearance_csv = None
        # Drop the prior slot's checked-locations resync; the new slot has its
        # own checked_locations universe (different ids, different progress).
        self.checked_csv = None

    async def run_tcp_server(self) -> None:
        try:
            server = await asyncio.start_server(
                self.handle_game_connection, GAME_TCP_HOST, GAME_TCP_PORT
            )
        except OSError as exc:
            # Surface a bind failure in the client window (ui_logger), not just
            # the file log. Without this the listener silently dies and the game
            # never connects with no obvious reason.
            ui_logger.error(
                f"Could not open the game connection port {GAME_TCP_HOST}:{GAME_TCP_PORT} "
                f"({exc}). Another program is already using it (often a second client "
                f"instance, or a local Archipelago server set to this port). Close it and "
                f"restart the client."
            )
            return
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
    # basicConfig (not just setLevel). Without an explicit handler, INFO-level
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
