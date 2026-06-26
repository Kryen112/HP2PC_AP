"""Generate apworld/{items,locations,regions,rules}.py and the mod's
APLocationRegistry/APCardAppearance/APCardMarker_*.uc from data/*.yaml.

Run from the repo root:
    py -3.12 gen_apworld.py

Re-run after editing any data/*.yaml and commit the regenerated files.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parent
DATA_DIR = REPO_ROOT / "data"
APWORLD_DIR = REPO_ROOT / "apworld"
MOD_CLASSES_DIR = REPO_ROOT / "mod" / "HPArchipelago" / "Classes"

# AP framework checkout. Required for the final `Build APWorlds` step that
# zips the apworld for cross-platform distribution (Linux can't follow the
# Windows-only junction the dev loop uses). Env var override for non-standard
# layouts; default follows DEV_SETUP's sibling-of-HP2PC_AP convention.
AP_FRAMEWORK_DIR = Path(
    os.environ.get("HP2_AP_FRAMEWORK_DIR") or (REPO_ROOT / ".." / ".." / "Archipelago")
).resolve()
APWORLD_GAME_NAME = "Harry Potter 2 PC"

# --- LOCAL ONLY, do not commit -------------------------------------------
# Copy the built apworld into each local Archipelago custom_worlds so the
# running generator / client / launcher pick up the rebuild. Machine-specific
# paths; override with HP2_APWORLD_INSTALL_DIRS (os.pathsep-separated).
_DEFAULT_APWORLD_INSTALL_DIRS = [
    # The frozen install used to generate seeds and run the client/launcher.
    # The dev checkout is NOT a target: it loads the world from the
    # worlds/harry_potter_2_pc junction to this repo's apworld/ (DEV_SETUP).
    Path(r"C:\ProgramData\Archipelago\custom_worlds"),
]
APWORLD_INSTALL_DIRS = (
    [Path(p) for p in os.environ["HP2_APWORLD_INSTALL_DIRS"].split(os.pathsep)]
    if os.environ.get("HP2_APWORLD_INSTALL_DIRS")
    else _DEFAULT_APWORLD_INSTALL_DIRS
)
# --- end LOCAL ONLY -------------------------------------------------------

LOCATION_CATEGORIES = (
    "classrooms",
    "special_checks",
    "cards",
    "quidditch_purchases",
    "duels",
    "quidditch_matches",
    "spell_challenge_times",
    "secrets",
    "challenge_stars",
    "level_completions",
    "tradersanity",
    "containers",
)

# Non-card-location dedupe window. Mirrors `NONCARD_LOC_WINDOW` in
# mod/HPArchipelago/Classes/APCardWatcher.uc. The two MUST hold the same
# value. A non-card location whose id_offset >= this falls outside the mod's
# NonCardLocationChecked[] array, so its dedupe is silently skipped and the
# check re-fires on level re-entry / save-load. Card-location and item offsets
# are deliberately NOT gated. Widened to 2048 to hold the containersanity band
# (offsets 1024+, 274 containers); the APCardWatcher.uc / APVendorMarker_Trader.uc
# / APContainerMarker.uc array dims + consts were widened to the same value.
NONCARD_LOC_WINDOW = 2048
CARD_LOCATION_CATEGORY = "cards"




# UScript card Id (set on each WC*.uc class default) → UScript class name.
# Extracted from HGame/Classes/StatusItems/StatusItemWizardCards.uc:GetCardClassFromId.
# This is the runtime mapping the mod uses; stable across game versions.
CARD_GAME_ID_TO_CLASS: dict[int, str] = {
    1: "WCMerlin", 2: "WCAgrippa", 3: "WCClagg", 4: "WCStump", 5: "WCPokeby",
    6: "WCPeakes", 7: "WCStarkey", 8: "WCShimpling", 9: "WCGunhilda", 10: "WCMuldoon",
    11: "WCHerpo", 12: "WCMerwyn", 13: "WCAndros", 14: "WCFulbert", 15: "WCParacelsus",
    16: "WCCliodne", 17: "WCFay", 18: "WCUlric", 19: "WCScamander", 20: "WCWendelin",
    21: "WCWithers", 22: "WCCirce", 23: "WCChittock", 24: "WCWaffling", 25: "WCFancourt",
    26: "WCSawbridge", 27: "WCPlunkett", 28: "WCToke", 29: "WCAlderton", 30: "WCLufkin",
    31: "WCBlane", 32: "WCWenlock", 33: "WCMarjoribanks", 34: "WCTremlett", 35: "WCWright",
    36: "WCWadcock", 37: "WCVablatsky", 38: "WCOldridge", 39: "WCJones", 40: "WCPinkstone",
    41: "WCGriffindor", 42: "WCCronk", 43: "WCYoudle", 44: "WCWhitehorn", 45: "WCOglethorpe",
    46: "WCGoshawk", 47: "WCStroulger", 48: "WCSlytherin", 49: "WCKetteridge", 50: "WCBarkwith",
    51: "WCEthelred", 52: "WCSummerbee", 53: "WCCatchlove", 54: "WCShingleton", 55: "WCNutcombe",
    56: "WCCrumb", 57: "WCOllerton", 58: "WCHipworth", 59: "WCGregory", 60: "WCMontmorency",
    61: "WCSweeting", 62: "WCWildsmith", 63: "WCWintringham", 64: "WCSykes", 65: "WCOliphant",
    66: "WCBelby", 67: "WCPilliwickle", 68: "WCDuke", 69: "WCBott", 70: "WCSmethwyck",
    71: "WCMaeve", 72: "WCHufflepuff", 73: "WCMopsus", 74: "WCKnightley", 75: "WCBonham",
    76: "WCWagtail", 77: "WCTwonk", 78: "WCThruston", 79: "WCBeamish", 80: "WCBloxam",
    81: "WCPo", 82: "WCRavenclaw", 83: "WCPlumpton", 84: "WCKegg", 85: "WCStalk",
    86: "WCWellbeloved", 87: "WCThurkell", 88: "WCWarbeck", 89: "WCToothill", 90: "WCTugwood",
    91: "WCElphick", 92: "WCRastrick", 93: "WCBarbary", 94: "WCGraves", 95: "WCPlatt",
    96: "WCWoodcroft", 97: "WCGrunnion", 98: "WCFurmage", 99: "WCDodderidge", 100: "WCPotter",
    101: "WCDumbledore",
}


# Per-card vendor metadata harvested from each WCXxx.uc default in
# HGame/Classes/WizardCards/. Stable across game versions. emit_card_markers
# copies these onto each generated APCardMarker_<X> subclass: vanilla
# AssignVendorCards reads slotClass.Default.Id and .bVendorsCanSell, and the
# markers inherit the WizardCardIcon sentinel Id=200 / bVendorsCanSell=False,
# so without the real per-card values vanilla skips every marker and the cards
# never reach vendor stock.
#
# Tuple is (bVendorsCanSell, strVendorOwnedAfterGState, tier); tier
# "Bronze"/"Silver"/"Gold" from the parent class (BronzeCards/SilverCards/
# Goldcards). All 11 gold cards are non-sellable; 59 of 101 are sellable.
CARD_VENDOR_META: dict[str, tuple[bool, str, str]] = {
    "WCAgrippa":      (True,  "GSTATE065", "Bronze"),
    "WCAlderton":     (False, "",          "Bronze"),
    "WCAndros":       (True,  "GSTATE180", "Silver"),
    "WCBarbary":      (False, "",          "Bronze"),
    "WCBarkwith":     (False, "",          "Bronze"),
    "WCBeamish":      (True,  "GSTATE100", "Silver"),
    "WCBelby":        (False, "",          "Bronze"),
    "WCBlane":        (False, "",          "Bronze"),
    "WCBloxam":       (True,  "GSTATE110", "Bronze"),
    "WCBonham":       (False, "",          "Bronze"),
    "WCBott":         (False, "",          "Gold"),
    "WCCatchlove":    (False, "",          "Bronze"),
    "WCChittock":     (True,  "GSTATE020", "Silver"),
    "WCCirce":        (True,  "GSTATE110", "Silver"),
    "WCClagg":        (True,  "GSTATE120", "Silver"),
    "WCCliodne":      (True,  "GSTATE150", "Silver"),
    "WCCronk":        (True,  "GSTATE065", "Silver"),
    "WCCrumb":        (True,  "GSTATE020", "Silver"),
    "WCDodderidge":   (True,  "GSTATE180", "Silver"),
    "WCDuke":         (True,  "GSTATE020", "Silver"),
    "WCDumbledore":   (False, "",          "Gold"),
    "WCElphick":      (True,  "GSTATE170", "Bronze"),
    "WCEthelred":     (False, "",          "Bronze"),
    "WCFancourt":     (True,  "GSTATE150", "Bronze"),
    "WCFay":          (True,  "GSTATE120", "Silver"),
    "WCFulbert":      (True,  "GSTATE050", "Silver"),
    "WCFurmage":      (True,  "GSTATE130", "Silver"),
    "WCGoshawk":      (True,  "GSTATE065", "Bronze"),
    "WCGraves":       (False, "",          "Bronze"),
    "WCGregory":      (True,  "GSTATE050", "Silver"),
    "WCGriffindor":   (False, "",          "Gold"),
    "WCGrunnion":     (True,  "GSTATE130", "Silver"),
    "WCGunhilda":     (False, "",          "Bronze"),
    "WCHerpo":        (False, "",          "Gold"),
    "WCHipworth":     (False, "",          "Bronze"),
    "WCHufflepuff":   (False, "",          "Gold"),
    "WCJones":        (True,  "GSTATE180", "Silver"),
    "WCKegg":         (False, "",          "Bronze"),
    "WCKetteridge":   (False, "",          "Bronze"),
    "WCKnightley":    (False, "",          "Gold"),
    "WCLufkin":       (True,  "GSTATE180", "Silver"),
    "WCMaeve":        (True,  "GSTATE180", "Silver"),
    "WCMarjoribanks": (False, "",          "Bronze"),
    "WCMerlin":       (False, "",          "Bronze"),
    "WCMerwyn":       (False, "",          "Bronze"),
    "WCMontmorency":  (True,  "GSTATE180", "Silver"),
    "WCMopsus":       (True,  "GSTATE180", "Silver"),
    "WCMuldoon":      (True,  "GSTATE100", "Bronze"),
    "WCNutcombe":     (True,  "GSTATE065", "Silver"),
    "WCOglethorpe":   (True,  "GSTATE180", "Silver"),
    "WCOldridge":     (True,  "GSTATE180", "Silver"),
    "WCOliphant":     (True,  "GSTATE150", "Silver"),
    "WCOllerton":     (True,  "GSTATE150", "Bronze"),
    "WCParacelsus":   (False, "",          "Gold"),
    "WCPeakes":       (True,  "GSTATE065", "Bronze"),
    "WCPilliwickle":  (True,  "GSTATE120", "Bronze"),
    "WCPinkstone":    (False, "",          "Gold"),
    "WCPlatt":        (True,  "GSTATE120", "Bronze"),
    "WCPlumpton":     (True,  "GSTATE110", "Bronze"),
    "WCPlunkett":     (True,  "GSTATE180", "Silver"),
    "WCPo":           (False, "",          "Bronze"),
    "WCPokeby":       (False, "",          "Bronze"),
    "WCPotter":       (False, "",          "Gold"),
    "WCRastrick":     (True,  "GSTATE130", "Silver"),
    "WCRavenclaw":    (False, "",          "Gold"),
    "WCSawbridge":    (False, "",          "Bronze"),
    "WCScamander":    (True,  "GSTATE150", "Bronze"),
    "WCShimpling":    (True,  "GSTATE080", "Silver"),
    "WCShingleton":   (True,  "GSTATE180", "Silver"),
    "WCSlytherin":    (False, "",          "Gold"),
    "WCSmethwyck":    (True,  "GSTATE080", "Silver"),
    "WCStalk":        (True,  "GSTATE080", "Silver"),
    "WCStarkey":      (True,  "GSTATE000", "Bronze"),
    "WCStroulger":    (True,  "GSTATE110", "Bronze"),
    "WCStump":        (True,  "GSTATE065", "Bronze"),
    "WCSummerbee":    (True,  "GSTATE130", "Silver"),
    "WCSweeting":     (False, "",          "Bronze"),
    "WCSykes":        (False, "",          "Bronze"),
    "WCThruston":     (False, "",          "Bronze"),
    "WCThurkell":     (True,  "GSTATE080", "Silver"),
    "WCToke":         (True,  "GSTATE090", "Bronze"),
    "WCToothill":     (True,  "GSTATE180", "Silver"),
    "WCTremlett":     (True,  "GSTATE020", "Silver"),
    "WCTugwood":      (True,  "GSTATE090", "Silver"),
    "WCTwonk":        (False, "",          "Bronze"),
    "WCUlric":        (False, "",          "Bronze"),
    "WCVablatsky":    (False, "",          "Bronze"),
    "WCWadcock":      (True,  "GSTATE180", "Silver"),
    "WCWaffling":     (True,  "GSTATE120", "Bronze"),
    "WCWagtail":      (False, "",          "Bronze"),
    "WCWarbeck":      (False, "",          "Bronze"),
    "WCWellbeloved":  (True,  "GSTATE150", "Bronze"),
    "WCWendelin":     (True,  "GSTATE180", "Silver"),
    "WCWenlock":      (False, "",          "Bronze"),
    "WCWhitehorn":    (True,  "GSTATE110", "Bronze"),
    "WCWildsmith":    (True,  "GSTATE110", "Silver"),
    "WCWintringham":  (False, "",          "Bronze"),
    "WCWithers":      (False, "",          "Bronze"),
    "WCWoodcroft":    (False, "",          "Bronze"),
    "WCWright":       (True,  "GSTATE180", "Silver"),
    "WCYoudle":       (True,  "GSTATE180", "Silver"),
}


# Cards the level designer placed mid-air. Our APCardMarker.Spawned() defaults
# to PHYS_Falling so chest ejections fall and mover-attached cards (e.g.
# WCElphick on the Chamber-II descending platform) get pushed by the mover's
# collision sweep. That breaks placements where vanilla wanted the card pinned
# in the air (vanilla level-loaded WizardCardIcon defaults to PHYS_None, which
# pins). For each card listed here, gen_apworld emits `bIsFloatingCard=True`
# on the generated marker subclass; APCardMarker.Spawned() then keeps PHYS_None
# instead of switching to PHYS_Falling.
#
# Add cards here as they're discovered. The check is exact-name
# against the WC class, e.g. "WCToothill".
FLOATING_CARDS: set[str] = {
    "WCToothill",  # Grand Staircase. Floats at the top, requires Spongify-jump.
}


def load_data() -> tuple[dict, dict, dict, dict]:
    items = yaml.safe_load((DATA_DIR / "items.yaml").read_text(encoding="utf-8"))
    locations = yaml.safe_load((DATA_DIR / "locations.yaml").read_text(encoding="utf-8"))
    logic_levels = yaml.safe_load((DATA_DIR / "logic_levels.yaml").read_text(encoding="utf-8"))
    logic_vanilla = yaml.safe_load((DATA_DIR / "logic_vanilla.yaml").read_text(encoding="utf-8"))
    logic_open_castle = yaml.safe_load((DATA_DIR / "logic_open_castle.yaml").read_text(encoding="utf-8"))
    # Shared level-interior location rules live in logic_levels.yaml and merge
    # into both modes. Region entries + the castle-hub / Quidditch location rules
    # stay mode-specific in the per-mode files. A location belongs to either the
    # shared levels file or one mode file, never both. Overlap is an authoring
    # error, so flag it loudly rather than silently picking a winner.
    shared = logic_levels.get("locations") or {}
    for mode_logic, fname in ((logic_vanilla, "logic_vanilla.yaml"),
                              (logic_open_castle, "logic_open_castle.yaml")):
        mode_locs = mode_logic.setdefault("locations", {})
        overlap = set(shared) & set(mode_locs)
        if overlap:
            raise ValueError(
                f"{fname} and logic_levels.yaml both define location(s): {sorted(overlap)}"
            )
        mode_logic["locations"] = {**shared, **mode_locs}
    return items, locations, logic_vanilla, logic_open_castle


SILVER_CARDS_MACRO = "@all_silver_cards"
# Gold Card Room silver gate, both modes. @all_silver_cards and
# @silver_cards_at_least_<N> expand to a bare-ident sentinel that
# _emit_rule_body rewrites to state.has_from_list_unique(_SILVER_CARD_NAMES,
# player, N): the full silver count for @all_silver_cards, N for the explicit
# form. The poptracker generator mirrors the same call as
# count("silver_cards") >= N, so the items-menu silver counter is the live
# control in both modes. The in-game door (CardLockTrigger) wires Lock1@10 +
# Lock2@20, so open castle gates at 20; vanilla keeps the collect-them-all
# expectation at the full silver count.
_SILVER_AT_LEAST_MACRO_RE = re.compile(r"@silver_cards_at_least_(\d+)")
_SILVER_AT_LEAST_SENTINEL_RE = re.compile(r"^_HP2_silver_cards_at_least_(\d+)_$")


def _silver_sentinel(n: int) -> str:
    return f"_HP2_silver_cards_at_least_{n}_"


def _rule_string_slots(logic: dict) -> list[tuple[dict, str]]:
    """Every (container, key) holding a rule string in a logic dict."""
    slots: list[tuple[dict, str]] = []
    for meta in (logic.get("regions") or {}).values():
        if isinstance(meta, dict) and isinstance(meta.get("entry"), str):
            slots.append((meta, "entry"))
    for section in ("locations", "goal"):
        for meta in (logic.get(section) or {}).values():
            if isinstance(meta, dict) and isinstance(meta.get("requires"), str):
                slots.append((meta, "requires"))
    return slots


def expand_macros(logic: dict, items: dict, context: str) -> None:
    """Substitute rule-string macros in-place before validation.

    `@all_silver_cards` and `@silver_cards_at_least_<N>` both expand to a
    bare-ident sentinel that `_emit_rule_body` rewrites to
    `state.has_from_list_unique(_SILVER_CARD_NAMES, player, N)`. The full silver
    count for the former, N for the latter. Silver names come from
    items.yaml.cards_silver, so the threshold can never drift from the pool size.
    """
    silver_names = [e["name"] for e in items.get("cards_silver", [])]
    if not silver_names:
        raise ValueError(
            f"{context}: items.yaml has no cards_silver to expand {SILVER_CARDS_MACRO}"
        )
    full = _silver_sentinel(len(silver_names))
    slots = _rule_string_slots(logic)
    for meta, key in slots:
        meta[key] = meta[key].replace(SILVER_CARDS_MACRO, full)
        meta[key] = _SILVER_AT_LEAST_MACRO_RE.sub(
            lambda m: _silver_sentinel(int(m.group(1))), meta[key])
    leftover = sorted({
        m.group(0)
        for meta, key in slots
        for m in re.finditer(r"@[A-Za-z_][A-Za-z0-9_]*", meta[key])
    })
    if leftover:
        raise ValueError(
            f"{context}: unknown rule macro(s) {leftover}; defined: "
            f"{SILVER_CARDS_MACRO}, @silver_cards_at_least_<N>"
        )


# Reserved logic-flag tokens. Not items (never in items.yaml, never in the
# pool): each is a player-selected capability that, when its option is on,
# HP2World precollects as a code-less event item so `state.has(<flag>)` passes.
# Rules opt a location/region into a flag additively, e.g.
#   requires: "Spongify | Running"
# These names compile to the same `state.has(...)` an item would, so
# _emit_rule_body needs no special case; parse_rule only skips the unknown-item
# check for them, and rule_idents excludes them (like true/false/TBD) so they
# never read as item dependencies.
#   Running  - gaps clearable by the always-on run speed instead of a spell.
#   Glitched - umbrella for every glitch shortcut.
LOGIC_FLAG_NAMES: frozenset[str] = frozenset({"Running", "Glitched"})


def parse_rule(rule_str: str, known_items: set[str], context: str) -> str:
    """Convert a logic.yaml rule string to a Python expression body.

    Grammar: identifiers (item names) joined by `&` (AND), `|` (OR), with
    parens for grouping. Special idents: `true`, `false`, `TBD`.

    Returns a string like 'state.has("Lumos", player) and state.has("Flipendo", player)'
    suitable for embedding in a `lambda state, player: <expr>` body.
    """
    s = (rule_str or "true").strip()
    if s == "true":
        return "True"
    if s == "false":
        return "False"
    if s == "TBD":
        # Lenient: treat TBD as always-reachable so seeds still generate.
        # validate_logic() collects TBDs separately for the dev-warning list.
        return "True"

    unknown: list[str] = []

    def replace_ident(m: re.Match) -> str:
        text = m.group(0)
        if text.startswith("'"):
            ident = text[1:-1]  # strip surrounding single quotes
        else:
            ident = text
        if ident in ("true", "True"):
            return "True"
        if ident in ("false", "False"):
            return "False"
        if ident == "TBD":
            return "True"
        if _SILVER_AT_LEAST_SENTINEL_RE.match(ident):
            return "True"  # validation placeholder; _emit_rule_body emits the real call
        if ident in LOGIC_FLAG_NAMES:
            return f"state.has({ident!r}, player)"
        if ident not in known_items:
            unknown.append(ident)
        return f"state.has({ident!r}, player)"

    # Grammar accepts either a bare single-token identifier OR a single-quoted
    # multi-word identifier, e.g. `'Forbidden Forest Key'`. The quoted form
    # comes first in the alternation so it wins on multi-word matches.
    body = re.sub(r"'[^']+'|[A-Za-z_][A-Za-z0-9_]*", replace_ident, s)
    body = body.replace("&", " and ").replace("|", " or ")

    if unknown:
        raise ValueError(
            f"{context}: rule {rule_str!r} references unknown item(s): {sorted(set(unknown))}. "
            f"Items must match data/items.yaml `name:` fields."
        )
    return body


_RULE_TOKEN_RE = re.compile(r"'[^']+'|[A-Za-z_][A-Za-z0-9_]*")


def rule_idents(rule_str: str) -> set[str]:
    """Item names a rule expression references (true/false/TBD excluded).

    Same tokenisation as parse_rule: single-quoted multi-word identifier or
    bare single-token. Used to decide whether a missable secret's full
    requirement is satisfiable from the precollected starting inventory.
    """
    out: set[str] = set()
    for m in _RULE_TOKEN_RE.finditer(rule_str or ""):
        tok = m.group(0)
        ident = tok[1:-1] if tok.startswith("'") else tok
        if ident in ("true", "True", "false", "False", "TBD"):
            continue
        if _SILVER_AT_LEAST_SENTINEL_RE.match(ident):
            continue
        if ident in LOGIC_FLAG_NAMES:
            continue
        out.add(ident)
    return out


def collect_known_items(items: dict) -> set[str]:
    names: set[str] = set()
    categories = ("spells", "key_items", "blocker_keys", "cards_bronze", "cards_silver",
                  "cards_gold", "equipment", "filler", "traps")
    for category in categories:
        for entry in items.get(category, []):
            names.add(entry["name"])
    # Silver-gate sentinels from expand_macros aren't items; parse_rule and
    # rule_idents recognise them by pattern, _emit_rule_body rewrites them.
    return names


def validate_logic(logic: dict, locations: dict, known_items: set[str]) -> tuple[str, list[str]]:
    """Validate logic.yaml. Returns (start_region_name, all_region_names_sorted)."""
    regions = logic.get("regions") or {}
    if not regions:
        raise ValueError("logic.yaml missing `regions:` section")

    start_regions = [name for name, meta in regions.items() if (meta or {}).get("start")]
    if len(start_regions) != 1:
        raise ValueError(
            f"logic.yaml must have exactly one region with `start: true` (found {len(start_regions)}: {start_regions})"
        )
    start_region = start_regions[0]

    # Validate region entry rules
    for region_name, meta in regions.items():
        meta = meta or {}
        rule = meta.get("entry", "true")
        parse_rule(rule, known_items, f"region {region_name!r} entry")

    # Cross-check: every region used in locations.yaml must be defined in logic.yaml
    # (allow "TBD" as a valid placeholder for iteration).
    used_regions = {entry.get("region", "TBD") for category in LOCATION_CATEGORIES for entry in locations.get(category, [])}
    used_regions.discard("TBD")  # TBD is implicit
    missing = used_regions - set(regions.keys())
    if missing:
        raise ValueError(
            f"locations.yaml references region(s) not defined in logic.yaml `regions:`: {sorted(missing)}"
        )

    # Validate per-location overrides
    location_rules = logic.get("locations") or {}
    location_names_set = {entry["name"] for category in LOCATION_CATEGORIES for entry in locations.get(category, [])}
    for loc_name, meta in location_rules.items():
        meta = meta or {}
        if loc_name not in location_names_set:
            raise ValueError(
                f"logic.yaml `locations:` key {loc_name!r} not found in data/locations.yaml"
            )
        parse_rule(meta.get("requires", "true"), known_items, f"location {loc_name!r} requires")

    # Validate goal
    goal = logic.get("goal") or {}
    for goal_name, meta in goal.items():
        parse_rule((meta or {}).get("requires", "true"), known_items, f"goal {goal_name!r} requires")
        for loc in (meta or {}).get("requires_completed", []):
            if loc not in location_names_set:
                raise ValueError(
                    f"goal {goal_name!r} requires_completed references unknown location {loc!r}"
                )

    # Collect TBD entries for dev warning (lenient mode treats TBD as reachable).
    tbd_regions = [name for name, meta in regions.items() if (meta or {}).get("entry", "true") == "TBD"]
    tbd_locations = [name for name, meta in (logic.get("locations") or {}).items() if (meta or {}).get("requires", "true") == "TBD"]
    if tbd_regions or tbd_locations:
        print(f"WARNING: {len(tbd_regions)} region(s) and {len(tbd_locations)} location(s) still TBD (lenient: treated as always-reachable):", file=sys.stderr)
        for name in sorted(tbd_regions):
            print(f"  region {name}: entry TBD", file=sys.stderr)
        for name in sorted(tbd_locations):
            print(f"  location {name}: requires TBD", file=sys.stderr)

    all_regions = sorted(regions.keys())
    return start_region, all_regions


def validate(items: dict, locations: dict) -> None:
    item_ids: set[int] = set()
    item_names: set[str] = set()
    item_base = items["base_id"]
    for category in ("spells", "key_items", "blocker_keys", "equipment", "cards_bronze", "cards_silver", "cards_gold", "filler", "traps"):
        for entry in items.get(category, []):
            iid = item_base + entry["id_offset"]
            if iid in item_ids:
                raise ValueError(f"Duplicate item id {iid} (offset {entry['id_offset']}) in {category}")
            item_ids.add(iid)
            if entry["name"] in item_names:
                raise ValueError(f"Duplicate item name {entry['name']!r} in {category}")
            item_names.add(entry["name"])

    loc_ids: set[int] = set()
    loc_names: set[str] = set()
    loc_base = locations["base_id"]
    for category in LOCATION_CATEGORIES:
        for entry in locations.get(category, []):
            lid = loc_base + entry["id_offset"]
            if lid in loc_ids:
                raise ValueError(f"Duplicate location id {lid} (offset {entry['id_offset']}) in {category}")
            loc_ids.add(lid)
            if entry["name"] in loc_names:
                raise ValueError(f"Duplicate location name {entry['name']!r} in {category}")
            loc_names.add(entry["name"])
            if category != CARD_LOCATION_CATEGORY and entry["id_offset"] >= NONCARD_LOC_WINDOW:
                raise ValueError(
                    f"Non-card location {entry['name']!r} (category {category!r}) has "
                    f"id_offset {entry['id_offset']} >= NONCARD_LOC_WINDOW ({NONCARD_LOC_WINDOW}): "
                    f"it falls outside the mod's NonCardLocationChecked[] dedupe window, so "
                    f"the check would re-fire on every level re-entry / save-load. Pick an "
                    f"in-window band."
                )

    classes_in_items = {e["class"] for cat in ("cards_bronze", "cards_silver", "cards_gold") for e in items.get(cat, [])}
    classes_in_locs = {e["card_class"] for e in locations.get("cards", [])}
    if classes_in_items != classes_in_locs:
        only_items = classes_in_items - classes_in_locs
        only_locs = classes_in_locs - classes_in_items
        raise ValueError(
            f"items.yaml and locations.yaml card classes mismatch. "
            f"Only in items: {sorted(only_items)}. Only in locations: {sorted(only_locs)}."
        )

    classes_known = set(CARD_GAME_ID_TO_CLASS.values())
    if classes_in_items != classes_known:
        only_yaml = classes_in_items - classes_known
        only_decomp = classes_known - classes_in_items
        raise ValueError(
            f"items.yaml cards vs decompiled GetCardClassFromId mismatch. "
            f"Only in yaml: {sorted(only_yaml)}. Only in decompile map: {sorted(only_decomp)}."
        )


def emit_items(items: dict) -> str:
    base = items["base_id"]
    lines: list[str] = [
        '"""Auto-generated. Do not edit by hand; regenerate from data/items.yaml."""',
        "",
        "from BaseClasses import ItemClassification",
        "",
        f"BASE_ID = {base}",
        "",
        "ITEM_NAME_TO_ID: dict[str, int] = {",
    ]

    def cls_token(s: str) -> str:
        return f"ItemClassification.{s}"

    rows: list[tuple[str, int, str, str]] = []
    spells_names: list[str] = []
    keys_names: list[str] = []
    blocker_keys_names: list[str] = []
    equipment_names: list[str] = []
    bronze_names: list[str] = []
    silver_names: list[str] = []
    gold_names: list[str] = []
    filler_names: list[str] = []
    trap_names: list[str] = []
    classifications: list[tuple[str, str]] = []
    card_class_to_item_name: list[tuple[str, str]] = []

    def add(entry: dict, classification_default: str | None, group_list: list[str]) -> None:
        cls = entry.get("classification", classification_default)
        if cls is None:
            raise ValueError(f"missing classification for {entry}")
        rows.append((entry["name"], base + entry["id_offset"], "", ""))
        classifications.append((entry["name"], cls_token(cls)))
        group_list.append(entry["name"])

    for entry in items.get("spells", []):
        add(entry, None, spells_names)
    for entry in items.get("key_items", []):
        add(entry, None, keys_names)
    for entry in items.get("blocker_keys", []):
        add(entry, None, blocker_keys_names)
    for entry in items.get("equipment", []):
        # Fred/George vendor items. Paired with `enable_quidditch_upgrades`:
        # gen_apworld emits them into ITEM_NAME_TO_ID unconditionally (stable
        # AP id space across toggle flips) but HP2World.create_items skips
        # them when the toggle is off, alongside the matching locations.
        add(entry, None, equipment_names)
    for entry in items.get("cards_bronze", []):
        # cards default to useful unless overridden.
        e2 = {**entry, "classification": entry.get("classification", "useful")}
        add(e2, None, bronze_names)
        card_class_to_item_name.append((entry["class"], entry["name"]))
    for entry in items.get("cards_silver", []):
        # Silvers default to progression_skip_balancing, not useful: the
        # GoldCardRoom silver-gate in HP2World.set_rules needs
        # state.has(silver, player), which only sees advancement-flagged
        # items (progression / progression_skip_balancing); useful-tier items
        # would never satisfy it. skip_balancing keeps silvers out of
        # progression rebalancing since they aren't required for the basilisk
        # goal.
        e2 = {**entry, "classification": entry.get("classification", "progression_skip_balancing")}
        add(e2, None, silver_names)
        card_class_to_item_name.append((entry["class"], entry["name"]))
    for entry in items.get("cards_gold", []):
        # Gold cards default to filler: they unlock nothing in vanilla (no
        # game-side reward (only silvers feed StatusItemLock1..4 / the Gold
        # Card Room) and no logic_*.yaml rule references a gold card). Open
        # castle still guarantees them reachable: HP2World.create_item promotes
        # every card to progression_skip_balancing in open castle mode
        # regardless of this default, since open_castle_goal_cards counts all
        # 101 cards.
        e2 = {**entry, "classification": entry.get("classification", "filler")}
        add(e2, None, gold_names)
        card_class_to_item_name.append((entry["class"], entry["name"]))
    for entry in items.get("filler", []):
        add(entry, None, filler_names)
    # Traps mirror filler structurally (pool items handed out, effect on
    # GRANT) but carry classification: trap. HP2World.create_items partitions
    # the filler delta between FILLER_NAMES and the player-selected subset of
    # TRAP_NAMES per the `traps` OptionSet / trap_fill_percent options.
    for entry in items.get("traps", []):
        add(entry, None, trap_names)

    for name, ap_id, _, _ in rows:
        lines.append(f"    {name!r}: {ap_id},")
    lines.append("}")
    lines.append("")
    lines.append("ITEM_CLASSIFICATIONS: dict[str, ItemClassification] = {")
    for name, cls in classifications:
        lines.append(f"    {name!r}: {cls},")
    lines.append("}")
    lines.append("")
    lines.append("ITEM_GROUPS: dict[str, list[str]] = {")
    lines.append(f"    'Spells': {spells_names!r},")
    lines.append(f"    'Key Items': {keys_names!r},")
    lines.append(f"    'Blocker Keys': {blocker_keys_names!r},")
    lines.append(f"    'Equipment': {equipment_names!r},")
    lines.append(f"    'Cards (Bronze)': {bronze_names!r},")
    lines.append(f"    'Cards (Silver)': {silver_names!r},")
    lines.append(f"    'Cards (Gold)': {gold_names!r},")
    lines.append(f"    'Filler': {filler_names!r},")
    lines.append(f"    'Traps': {trap_names!r},")
    lines.append("}")
    lines.append("")
    lines.append(f"FILLER_NAMES: list[str] = {filler_names!r}")
    lines.append(f"TRAP_NAMES: list[str] = {trap_names!r}")
    lines.append("")
    lines.append("# Map UScript card class name → AP item display name. Used by the client")
    lines.append("# when forwarding 'GRANT <classname>' messages to the mod for cards.")
    lines.append("CARD_CLASS_TO_ITEM_NAME: dict[str, str] = {")
    for ucls, iname in card_class_to_item_name:
        lines.append(f"    {ucls!r}: {iname!r},")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def emit_locations(locations: dict, items: dict) -> str:
    base = locations["base_id"]
    lines: list[str] = [
        '"""Auto-generated. Do not edit by hand; regenerate from data/locations.yaml."""',
        "",
        f"BASE_ID = {base}",
        "",
        "LOCATION_NAME_TO_ID: dict[str, int] = {",
    ]
    region_pairs: list[tuple[str, str]] = []
    group_pairs: list[tuple[str, str]] = []
    card_class_to_loc: list[tuple[str, str]] = []
    card_game_id_to_loc_name: list[tuple[int, str]] = []

    name_to_id: list[tuple[str, int]] = []
    for category in LOCATION_CATEGORIES:
        for entry in locations.get(category, []):
            name = entry["name"]
            ap_id = base + entry["id_offset"]
            name_to_id.append((name, ap_id))
            region_pairs.append((name, entry.get("region", "TBD")))
            group_pairs.append((name, entry.get("group", category)))
            if category == "cards":
                card_class_to_loc.append((entry["card_class"], name))

    # Build game_id → location_name via the canonical UScript map.
    class_to_loc = dict(card_class_to_loc)
    for game_id, ucls in CARD_GAME_ID_TO_CLASS.items():
        loc_name = class_to_loc.get(ucls)
        if loc_name is None:
            raise ValueError(f"No card location for class {ucls} (game_id {game_id})")
        card_game_id_to_loc_name.append((game_id, loc_name))

    for name, ap_id in name_to_id:
        lines.append(f"    {name!r}: {ap_id},")
    lines.append("}")
    lines.append("")
    lines.append("LOCATION_REGIONS: dict[str, str] = {")
    for name, region in region_pairs:
        lines.append(f"    {name!r}: {region!r},")
    lines.append("}")
    lines.append("")
    lines.append("LOCATION_GROUPS: dict[str, str] = {")
    for name, group in group_pairs:
        lines.append(f"    {name!r}: {group!r},")
    lines.append("}")
    lines.append("")
    lines.append("# Map UScript card class name → AP location name. Used by the client to")
    lines.append("# resolve a game CHECK to the right AP location for LocationChecks.")
    lines.append("CARD_CLASS_TO_LOCATION_NAME: dict[str, str] = {")
    for ucls, loc_name in card_class_to_loc:
        lines.append(f"    {ucls!r}: {loc_name!r},")
    lines.append("}")
    lines.append("")
    lines.append("# Map game-side card Id (the UScript WC*.uc default Id property) → AP")
    lines.append("# location name. Client receives 'CHECK <int>' from the mod and uses")
    lines.append("# this to find the AP location to send LocationChecks for.")
    lines.append("CARD_GAME_ID_TO_LOCATION_NAME: dict[int, str] = {")
    for game_id, loc_name in sorted(card_game_id_to_loc_name):
        lines.append(f"    {game_id}: {loc_name!r},")
    lines.append("}")
    lines.append("")
    # Map each wizard-card item name → its own card location. When card shuffle
    # is off, HP2World locks every card at its own spot using this, so the
    # silver-card gate (Gold Card Room) stays honest. card_class -> location is
    # the bridge; every card item carries its class in items.yaml.
    card_item_to_loc: list[tuple[str, str]] = []
    for tier in ("cards_bronze", "cards_silver", "cards_gold"):
        for entry in items.get(tier, []):
            loc_name = class_to_loc.get(entry["class"])
            if loc_name is None:
                raise ValueError(
                    f"{tier} class {entry['class']!r} has no card location in locations.yaml"
                )
            card_item_to_loc.append((entry["name"], loc_name))
    lines.append("CARD_ITEM_NAME_TO_LOCATION_NAME: dict[str, str] = {")
    for item_name, loc_name in card_item_to_loc:
        lines.append(f"    {item_name!r}: {loc_name!r},")
    lines.append("}")
    lines.append("")

    # Gold-card vault location set: the GoldCardRoom placement exclusions in
    # HP2World.set_rules (no silver may be placed here in any mode; no key or
    # spell may be placed here in open castle). Every location in the
    # GoldCardRoom region sits behind the silver-card wall, so derive from
    # region. That is the 11 gold cards plus the "Gold Card Room - Complete"
    # level-completion. The gold-tier classification is still walked first so
    # validate()'s items-vs-locations card-class parity check applies and every
    # gold class is guaranteed a location.
    goldroom_names: set[str] = set()
    for entry in items.get("cards_gold", []):
        ucls = entry["class"]
        loc_name = class_to_loc.get(ucls)
        if loc_name is None:
            raise ValueError(
                f"cards_gold class {ucls!r} has no card location in locations.yaml"
            )
        goldroom_names.add(loc_name)
    goldroom_names.update(name for name, region in region_pairs if region == "GoldCardRoom")
    lines.append("GOLD_CARD_ROOM_LOCATIONS: frozenset = frozenset({")
    for n in sorted(goldroom_names):
        lines.append(f"    {n!r},")
    lines.append("})")
    lines.append("")
    lines.append("# Locations in one-way (un-replayable) levels: permanently lost once")
    lines.append("# the level is left behind. Secrets flagged missable, plus every")
    lines.append("# container in a one-way story region. HP2World keeps these filler-only")
    lines.append("# unless allow_missable_progression is set AND every item they depend on")
    lines.append("# is precollected (so the player is guaranteed to hold it while passing")
    lines.append("# through the level the one time it is reachable).")
    lines.append("MISSABLE_LOCATIONS: frozenset = frozenset({")
    for n in locations.get("missable_locations", []):
        lines.append(f"    {n!r},")
    lines.append("})")
    lines.append("")
    lines.append("# Item names appearing in (region entry AND location requires) for")
    lines.append("# each missable location. Vanilla-only: the missable system is a")
    lines.append("# vanilla concept (open castle replays every level), so there is no")
    lines.append("# open castle dependency table. A subset of the precollected starting")
    lines.append("# inventory means the location is reachable from the start.")
    lines.append("MISSABLE_LOCATION_DEPS_VANILLA: dict[str, list[str]] = {")
    for n, deps in locations.get("missable_location_deps_vanilla", {}).items():
        lines.append(f"    {n!r}: {deps!r},")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def _emit_region_table(table_name: str, regions: dict, start_region: str) -> list[str]:
    out = [
        f"{table_name}: dict[str, Callable[[CollectionState, int], bool]] = {{",
    ]
    for region_name in sorted(regions.keys()):
        meta = regions[region_name] or {}
        if region_name == start_region:
            continue
        rule_str = meta.get("entry", "true")
        body = _emit_rule_body(rule_str)
        out.append(f"    {region_name!r}: lambda state, player: {body},")
    out.append("}")
    out.append("")
    return out


def _emit_regions_dual(
    regions_vanilla: dict,
    regions_open_castle: dict,
    start_region: str,
    all_regions: list[str],
    items: dict,
) -> str:
    """Emit apworld/regions.py with both vanilla and open castle entry-rule tables."""
    silver_names = [e["name"] for e in items.get("cards_silver", [])]
    lines: list[str] = [
        '"""Auto-generated. Do not edit by hand; regenerate from data/logic_vanilla.yaml + data/logic_open_castle.yaml."""',
        "",
        "from typing import Callable",
        "",
        "from BaseClasses import CollectionState",
        "",
        f"START_REGION: str = {start_region!r}",
        "",
        f"REGION_NAMES: list[str] = {all_regions!r}",
        "",
        "# Silver card item names. Referenced by the Gold Card Room gate in both",
        "# modes via has_from_list_unique (open castle needs 20, vanilla all of",
        "# them; the in-game CardLockTrigger wires Lock1+Lock2). Sourced from",
        "# items.yaml.cards_silver at gen time so it can never drift.",
        f"_SILVER_CARD_NAMES: list[str] = {silver_names!r}",
        "",
        "# region_name -> rule(state, player) -> bool. Mode-dependent: HP2World",
        "# selects vanilla or open castle at gen time via self.options.game_mode.",
    ]
    lines += _emit_region_table("REGION_ENTRY_RULES_VANILLA", regions_vanilla, start_region)
    lines += _emit_region_table("REGION_ENTRY_RULES_OPEN_CASTLE", regions_open_castle, start_region)
    return "\n".join(lines)


def _emit_rule_body(rule_str: str) -> str:
    """Convert rule string to lambda-body Python expression. No validation here.
    Caller has already validated via parse_rule(). TBD compiles to True (lenient)."""
    s = (rule_str or "true").strip()
    if s == "true" or s == "TBD":
        return "True"
    if s == "false":
        return "False"

    def replace_ident(m: re.Match) -> str:
        text = m.group(0)
        ident = text[1:-1] if text.startswith("'") else text
        if ident in ("true", "True", "TBD"):
            return "True"
        if ident in ("false", "False"):
            return "False"
        sentinel = _SILVER_AT_LEAST_SENTINEL_RE.match(ident)
        if sentinel:
            return (
                f"state.has_from_list_unique(_SILVER_CARD_NAMES, player, "
                f"{sentinel.group(1)})"
            )
        return f"state.has({ident!r}, player)"

    body = re.sub(r"'[^']+'|[A-Za-z_][A-Za-z0-9_]*", replace_ident, s)
    return body.replace("&", " and ").replace("|", " or ")


def _emit_location_table(table_name: str, location_rules: dict) -> list[str]:
    out = [f"{table_name}: dict[str, Callable[[CollectionState, int], bool]] = {{"]
    for loc_name in sorted(location_rules.keys()):
        meta = location_rules[loc_name] or {}
        body = _emit_rule_body(meta.get("requires", "true"))
        if body == "True":
            continue
        out.append(f"    {loc_name!r}: lambda state, player: {body},")
    out.append("}")
    out.append("")
    return out


def _emit_goal_rule_table(table_name: str, goal: dict) -> list[str]:
    out = [f"{table_name}: dict[str, Callable[[CollectionState, int], bool]] = {{"]
    for goal_name in sorted(goal.keys()):
        meta = goal[goal_name] or {}
        body = _emit_rule_body(meta.get("requires", "true"))
        if body == "True":
            continue
        out.append(f"    {goal_name!r}: lambda state, player: {body},")
    out.append("}")
    out.append("")
    return out


def _emit_goal_locations_table(table_name: str, goal: dict) -> list[str]:
    out = [f"{table_name}: dict[str, list[str]] = {{"]
    for goal_name in sorted(goal.keys()):
        meta = goal[goal_name] or {}
        reqs = meta.get("requires_completed", [])
        if reqs:
            out.append(f"    {goal_name!r}: {reqs!r},")
    out.append("}")
    out.append("")
    return out


def emit_rules_dual(logic_vanilla: dict, logic_open_castle: dict, locations: dict, items: dict) -> str:
    """Emit apworld/rules.py with both vanilla and open castle rule tables."""
    silver_names = [e["name"] for e in items.get("cards_silver", [])]
    lines: list[str] = [
        '"""Auto-generated. Do not edit by hand; regenerate from data/logic_levels.yaml + data/logic_vanilla.yaml + data/logic_open_castle.yaml."""',
        "",
        "from typing import Callable",
        "",
        "from BaseClasses import CollectionState",
        "",
        "# Silver card item names, referenced by per-location lambdas that gate",
        "# on the open-castle Gold Card Room (20-of-40 silvers, matching the",
        "# in-game CardLockTrigger that only wires Lock1+Lock2). Sourced from",
        "# items.yaml.cards_silver at gen time so it can never drift.",
        f"_SILVER_CARD_NAMES: list[str] = {silver_names!r}",
        "",
        "# Per-location additional rules (on top of region entry).",
        "# Mode-dependent: HP2World selects vanilla or open castle at gen time.",
    ]
    # Container baseline rules: each container's requirement is just its opening
    # spell (the `spell` field on the data/locations.yaml `containers` rows), so
    # the rows need no hand-authored logic entry. setdefault means an explicit
    # entry in logic_*.yaml `locations:` for the same name WINS. That is the
    # refine-by-hand path (add `'<name>': { requires: "<spell> & ..." }`).
    # BeanBonusRoom rows carry mode: open_castle, so they get an open-castle
    # rule only (vanilla disables them via OPEN_CASTLE_ONLY_REGIONS).
    van_locs = dict(logic_vanilla.get("locations") or {})
    oc_locs = dict(logic_open_castle.get("locations") or {})
    for row in locations.get("containers", []):
        baseline = {"requires": row["spell"]}
        oc_locs.setdefault(row["name"], baseline)
        if row.get("mode") != "open_castle":
            van_locs.setdefault(row["name"], baseline)
    lines += _emit_location_table("LOCATION_RULES_VANILLA", van_locs)
    lines += _emit_location_table("LOCATION_RULES_OPEN_CASTLE", oc_locs)

    lines.append("# goal_name -> direct item/logic rule for victory generation.")
    lines.append("# Vanilla only: open castle sets completion_condition from")
    lines.append("# _open_castle_complete (cards/spells has-counts + level-completion")
    lines.append("# reachability), so it needs no goal-rule table. Runtime completion")
    lines.append("# still comes from the game-side GOAL_COMPLETE signal.")
    lines += _emit_goal_rule_table("GOAL_RULES_VANILLA", logic_vanilla.get("goal") or {})

    lines.append("# Optional goal_name -> location names that must be reachable")
    lines.append("# for victory. Vanilla only, for the same reason as the goal-rule")
    lines.append("# table above (open castle uses _open_castle_complete).")
    lines += _emit_goal_locations_table("GOAL_LOCATION_REQUIREMENTS_VANILLA", logic_vanilla.get("goal") or {})
    return "\n".join(lines)


def emit_location_registry(locations: dict, base_id: int) -> int:
    """Emit mod/HPArchipelago/Classes/APLocationRegistry.uc.

    Three static lookups: secret-marker (LevelName, MarkerName) → AP location
    id, star-marker (LevelName, MarkerName) → AP location id, and vendor
    (LevelName, VendorName) → AP location id (Tradersanity). Returns 0 if a
    given key isn't registered (e.g. star in a non-challenge level, a vendor
    not in the seed's Tradersanity set). The watcher uses these to fire
    CHECK_LOCID on the correct AP location when bFound flips / a star vanishes
    / a tagged vendor's first sale is touched. Level names are normalised via
    Caps() in both the emitter and the watcher so case differences between
    Level.Outer.Name and the catalogue don't bite. Returns the total number of
    registered (level, key) pairs.
    """

    def expand_levels(level_field: "str | list[str]") -> list[str]:
        if isinstance(level_field, list):
            return list(level_field)
        return [level_field]

    secret_entries: list[tuple[str, str, int]] = []
    for row in locations.get("secrets", []):
        ap_id = base_id + row["id_offset"]
        for lvl in expand_levels(row["level"]):
            secret_entries.append((lvl.upper(), row["marker"], ap_id))

    star_entries: list[tuple[str, str, int]] = []
    for row in locations.get("challenge_stars", []):
        ap_id = base_id + row["id_offset"]
        for lvl in expand_levels(row["level"]):
            star_entries.append((lvl.upper(), row["marker"], ap_id))

    # Tradersanity: keyed on the vendor actor's stable Name (Phase 0 census
    # confirmed Names survive re-entry / save-load and match vanilla↔open castle),
    # so this is the exact same (level, key) → id shape as secrets.
    vendor_entries: list[tuple[str, str, int]] = []
    for row in locations.get("tradersanity", []):
        ap_id = base_id + row["id_offset"]
        for lvl in expand_levels(row["level"]):
            vendor_entries.append((lvl.upper(), row["vendor_name"], ap_id))

    # Original sell type per vendor, as Characters.ESells ordinals (mirrored
    # by SELLS_* in APCardWatcher.uc). The mod converts a pending card vendor
    # to an ingredient vendor at runtime, so it must read the ORIGINAL type
    # from here (not the mutated actor) to restore it on collection.
    _sells_code = {"WBark": 2, "FMucus": 3, "BronzeCards": 4, "SilverCards": 5}
    vendor_sells_entries: list[tuple[str, str, int]] = []
    for row in locations.get("tradersanity", []):
        code = _sells_code.get(str(row.get("sells", "")))
        if code is None:
            raise ValueError(
                f"tradersanity row {row.get('name')!r} has unknown sells "
                f"{row.get('sells')!r}; expected one of {sorted(_sells_code)}"
            )
        for lvl in expand_levels(row["level"]):
            vendor_sells_entries.append((lvl.upper(), row["vendor_name"], code))

    # containersanity: (level, actor Name) -> AP id for every bean container.
    # The mod's bring-up swap iterates the container families and uses this to
    # tell which placed instances are AP locations (returns 0 for non-locations
    # like card chests / decorative cauldrons, which it then leaves alone).
    container_entries: list[tuple[str, str, int]] = []
    for row in locations.get("containers", []):
        ap_id = base_id + row["id_offset"]
        for lvl in expand_levels(row["level"]):
            container_entries.append((lvl.upper(), row["marker"], ap_id))

    def emit_lookup(fn_name: str, entries: list[tuple[str, str, int]]) -> list[str]:
        by_level: dict[str, list[tuple[str, int]]] = {}
        for lvl, marker, ap_id in entries:
            by_level.setdefault(lvl, []).append((marker, ap_id))
        # UScript string literals use double-quotes; single-quote is reserved
        # for Name literals. Comparison is case-sensitive, hence Caps() on
        # LevelName + uppercase keys. Marker names keep original case; vanilla
        # Name preserves it on serialization.
        body: list[str] = [
            f"static function int {fn_name}(string LevelName, string MarkerName)",
            "{",
            "    LevelName = Caps(LevelName);",
        ]
        for i, (lvl, pairs) in enumerate(sorted(by_level.items())):
            keyword = "if" if i == 0 else "else if"
            body.append(f'    {keyword} (LevelName == "{lvl}")')
            body.append("    {")
            for marker, ap_id in sorted(pairs):
                body.append(f'        if (MarkerName == "{marker}") return {ap_id};')
            body.append("    }")
        body.append("    return 0;")
        body.append("}")
        return body

    out_path = MOD_CLASSES_DIR / "APLocationRegistry.uc"
    lines = [
        "// Auto-generated. Do not edit by hand; regenerate from",
        "// data/locations.yaml (secrets + challenge_stars + tradersanity + containers sections).",
        "class APLocationRegistry extends Object;",
        "",
    ]
    lines += emit_lookup("GetSecretLocationId", secret_entries)
    lines.append("")
    lines += emit_lookup("GetStarLocationId", star_entries)
    lines.append("")
    lines += emit_lookup("GetVendorLocationId", vendor_entries)
    lines.append("")
    lines += emit_lookup("GetVendorSells", vendor_sells_entries)
    lines.append("")
    lines += emit_lookup("GetContainerLocationId", container_entries)
    lines.append("")
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(secret_entries) + len(star_entries) + len(vendor_entries) + len(container_entries)


def emit_card_appearance_registry(locations: dict, base_id: int) -> int:
    """Emit mod/HPArchipelago/Classes/APCardAppearance.uc.

    Two static lookups keyed by game-side card id (1..101, the WC*.uc default
    Id property the markers carry as CardLocationId):

      CardIdToApId(id)        -> the card location's full AP id (base_id +
                                 id_offset), or 0 if the id is unknown. The #3
                                 appearance resolver does `apId - LOC_BASE` to
                                 index AppearanceCode[].
      CardClassNameForId(id)  -> the vanilla UScript card class name (e.g.
                                 "WCGriffindor"), or "" if unknown. The
                                 resolver DynamicLoadObjects "HGame."$name and
                                 reads .default.Skin so the morphed marker
                                 shows that exact card's face (the
                                 Griffindor/Gryffindor skin-name irregularity
                                 is auto-correct because it is read, never
                                 string-transformed).

    Built from CARD_GAME_ID_TO_CLASS (the canonical UScript id->class map) and
    the card-location id_offsets in data/locations.yaml. Mirrors
    emit_location_registry's structure (committed output, generator not
    shipped). Returns the number of registered card ids.
    """
    class_to_ap_id: dict[str, int] = {}
    for entry in locations.get("cards", []):
        class_to_ap_id[entry["card_class"]] = base_id + entry["id_offset"]

    id_to_ap: list[tuple[int, int]] = []
    id_to_class: list[tuple[int, str]] = []
    for game_id, ucls in sorted(CARD_GAME_ID_TO_CLASS.items()):
        ap_id = class_to_ap_id.get(ucls)
        if ap_id is None:
            raise ValueError(
                f"emit_card_appearance_registry: card class {ucls!r} (game id "
                f"{game_id}) has no card location in data/locations.yaml"
            )
        id_to_ap.append((game_id, ap_id))
        id_to_class.append((game_id, ucls))

    out_path = MOD_CLASSES_DIR / "APCardAppearance.uc"
    lines: list[str] = [
        "// Auto-generated. Do not edit by hand; regenerate from",
        "// data/locations.yaml (cards section) + CARD_GAME_ID_TO_CLASS.",
        "class APCardAppearance extends Object;",
        "",
        "// Game-side card id (1..101) -> full AP location id. The #3 resolver",
        "// indexes AppearanceCode[] by (return value - LOC_BASE).",
        "static function int CardIdToApId(int cardId)",
        "{",
        "    switch (cardId)",
        "    {",
    ]
    for game_id, ap_id in id_to_ap:
        lines.append(f"        case {game_id}: return {ap_id};")
    lines += [
        "    }",
        "    return 0;",
        "}",
        "",
        "// Game-side card id (1..101) -> vanilla UScript card class name. The",
        "// resolver reads <class>.default.Skin for the exact card face.",
        "static function string CardClassNameForId(int cardId)",
        "{",
        "    switch (cardId)",
        "    {",
    ]
    for game_id, ucls in id_to_class:
        lines.append(f'        case {game_id}: return "{ucls}";')
    lines += [
        "    }",
        '    return "";',
        "}",
    ]
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(id_to_ap)


def emit_card_markers(items: dict) -> int:
    """Emit one APCardMarker_<ClassName>.uc per card in CARD_GAME_ID_TO_CLASS.

    Each subclass extends APCardMarker (in mod/HPArchipelago/Classes/APCardMarker.uc,
    hand-authored) and sets `CardLocationId` to the card's game-side id. Vanilla
    chests/cauldrons hold a class reference in EjectedObjects; APGameInfo.InitGame
    swaps card classes for the corresponding marker subclass at every level entry.

    Each subclass also gets `soundPickup` set to the matching vanilla card-tier
    sound (pickup_WC_bronze / _silver / _gold), so AP marker pickups are audible.
    Markers extend WizardCardIcon directly, not the per-tier BronzeCards/etc., so
    they don't inherit a soundPickup default, so we set it here.

    Returns the number of marker files written.
    """
    # Build class -> tier and class -> AP display name from items.yaml's three
    # card lists. DisplayName flows into the emitted marker defaults so the mod
    # can echo the real AP item string (e.g. "Silver Card - Duke") in HUD
    # toasts via APGameInfo.FormatGrantText.
    class_to_tier: dict[str, str] = {}
    class_to_display: dict[str, str] = {}
    for tier in ("bronze", "silver", "gold"):
        for entry in items.get(f"cards_{tier}", []):
            class_to_tier[entry["class"]] = tier
            class_to_display[entry["class"]] = entry["name"]

    # Remove generated APCardMarker_WC*.uc so a shrunk data/items.yaml leaves
    # no stale files. Scoped to the WC prefix so it never deletes the
    # hand-authored APCardMarker subclasses (every generated card class in
    # CARD_GAME_ID_TO_CLASS starts with "WC").
    for stale in MOD_CLASSES_DIR.glob("APCardMarker_WC*.uc"):
        stale.unlink()

    written = 0
    for game_id, ucls in sorted(CARD_GAME_ID_TO_CLASS.items()):
        tier = class_to_tier.get(ucls)
        if tier is None:
            raise ValueError(
                f"emit_card_markers: no tier in items.yaml for card class {ucls!r}; "
                "add it to cards_bronze/cards_silver/cards_gold."
            )
        meta = CARD_VENDOR_META.get(ucls)
        if meta is None:
            raise ValueError(
                f"emit_card_markers: no vendor metadata for card class {ucls!r}; "
                "add it to CARD_VENDOR_META."
            )
        bvc, gst, marker_tier = meta
        bvc_uc = "True" if bvc else "False"
        floating = ucls in FLOATING_CARDS
        floating_line = "    bIsFloatingCard=True\n" if floating else ""
        display_name = class_to_display[ucls]
        path = MOD_CLASSES_DIR / f"APCardMarker_{ucls}.uc"
        path.write_text(
            "// Auto-generated. Do not edit by hand; regenerate from data/items.yaml.\n"
            f"class APCardMarker_{ucls} extends APCardMarker;\n"
            "\n"
            "defaultproperties\n"
            "{\n"
            f"    CardLocationId={game_id}\n"
            f"    soundPickup=Sound'HPSounds.Magic_sfx.pickup_WC_{tier}'\n"
            f"    bVendorsCanSell={bvc_uc}\n"
            f"    strVendorOwnedAfterGState=\"{gst}\"\n"
            f"    MarkerTier=\"{marker_tier}\"\n"
            f"    DisplayName=\"{display_name}\"\n"
            f"{floating_line}"
            "}\n",
            encoding="utf-8",
        )
        written += 1
    return written


# containersanity chest/cauldron families. APCardWatcher injects the baked AP
# marker into the NATIVE actor's EjectedObjects IN PLACE (no swap/destroy), so it
# pops first from the container's own eject queue with bean velocity and the
# inter-bean delay. In-place is mandatory: these actors persist in hub levels via
# SaveGame, and a destroyed-and-respawned cross-package subclass does not survive
# the restore (it vanishes). Matched case-insensitively against the row `class`.
CONTAINER_CHEST_CLASSES = frozenset({
    "chestbronze", "chestwood", "chestgold", "chestiron", "bronzecauldron",
})


# Single-content "jar" spawners whose whole vanilla payload is one ingredient
# goodie. For these the AP token REPLACES that goodie (drops instead of it)
# rather than being appended as an extra eject, so the jar yields only the AP
# check. Matched against the row `class` by exact name (these are the precise
# GenericSpawner leaf class names, not the case-folded chest keys above).
CONTAINER_REPLACE_CLASSES = frozenset({
    "BarkSpawn", "MucusSpawn",
})


def _spawner_subclass_text(leaf: str) -> str:
    """A thin GenericSpawner-leaf subclass that ejects the per-location baked-id
    marker as its OWN sequential eject -- not alongside a bean -- so it pops with
    the exact same velocity, bounce, and timing as a goodie.

    Two flavours, keyed on CONTAINER_REPLACE_CLASSES:
      - append (default): SwapContainerSpawner bumps Limits by +1 to buy one extra
        eject iteration for the token; the first SpawnObject undoes that +1 (so
        multi-life re-hits eject vanilla counts) then ejects the token, and the
        box's own goodies still drop on the remaining iterations.
      - replace (single-content jars, e.g. BarkSpawn/MucusSpawn): SwapContainerSpawner
        does NOT bump Limits, so the native eject count is unchanged. The token
        REPLACES the native goodie -- the first call ejects the token, every later
        call is suppressed, and the native goodie never spawns.
    Both route the token through the parent's goodie spawn by briefly pointing a
    GoodieToSpawn slot at the baked marker class. CheckLocationId is stamped by
    SwapContainerSpawner via APContainerStamp."""
    replace = leaf in CONTAINER_REPLACE_CLASSES
    header = (
        "// Auto-generated. Do not edit by hand; regenerate from\n"
        "// data/locations.yaml (containers) via gen_apworld.py.\n"
    )
    if replace:
        header += (
            f"// Swap target for {leaf} containers (single-content jars): the AP\n"
            "// token REPLACES the native goodie -- it drops INSTEAD OF the bark/\n"
            "// mucus, not alongside it. SwapContainerSpawner copies the instance\n"
            "// spawn config and, for replace leaves, does NOT bump Limits.\n"
        )
    else:
        header += (
            f"// Swap target for {leaf} containers: ejects the AP token as its own\n"
            "// sequential goodie (bean velocity / bounce / delay), then the box's own\n"
            "// goodies. SwapContainerSpawner copies the instance spawn config + bumps\n"
            "// Limits by 1 for the extra slot.\n"
        )
    decl = (
        f"class APContainerSpawner_{leaf} extends {leaf};\n"
        "\n"
        "const LOC_BASE = 5760000;\n"
        "var int CheckLocationId;\n"
        "var bool bAPTokenEjected;\n"
        "\n"
    )
    if replace:
        body = (
            "// SpawnObject runs once per ejected goodie. With no Limits bump the\n"
            "// native eject count is unchanged, so the first (and for a 1-goodie jar,\n"
            "// only) call ejects the AP token THROUGH the parent goodie spawn --\n"
            "// briefly pointing this slot at the baked marker class so it gets a\n"
            "// goodie's arc/velocity/bounce/persist -- then returns. Every later call\n"
            "// is suppressed, so the native goodie never spawns: the token replaces it.\n"
            "function SpawnObject(int Index)\n"
            "{\n"
            "    local class<Actor> markerCls, saved;\n"
            "    local int useIdx;\n"
            "\n"
            "    if (!bAPTokenEjected)\n"
            "    {\n"
            "        bAPTokenEjected = True;\n"
            "        if (CheckLocationId > 0)\n"
            "        {\n"
            "            markerCls = class<Actor>(DynamicLoadObject(\n"
            "                \"HPArchipelago.APContainerMarker_\" $ string(CheckLocationId - LOC_BASE), class'Class'));\n"
            "            if (markerCls != None)\n"
            "            {\n"
            "                useIdx = Index;\n"
            "                if (useIdx < 0) { useIdx = 0; }\n"
            "                saved = GoodieToSpawn[useIdx];\n"
            "                GoodieToSpawn[useIdx] = markerCls;\n"
            "                Super.SpawnObject(useIdx);\n"
            "                GoodieToSpawn[useIdx] = saved;\n"
            "                Log(\"[Archipelago] APContainerSpawner: ejected AP token (replace) for loc \" $ string(CheckLocationId));\n"
            "                return;\n"
            "            }\n"
            "        }\n"
            "        // Token unavailable: drop the native goodie so the jar is never empty.\n"
            "        Super.SpawnObject(Index);\n"
            "        return;\n"
            "    }\n"
            "    // Replace mode: native goodie suppressed; only the AP token drops.\n"
            "}\n"
        )
    else:
        body = (
            "// SpawnObject runs once per ejected goodie. On the first call (the extra\n"
            "// iteration the +1 Limits bump bought) eject the token THROUGH the parent\n"
            "// goodie spawn -- temporarily point this slot at the baked marker class so\n"
            "// Super.SpawnObject gives it the same arc/velocity/bounce/persist a bean\n"
            "// gets -- then return (this slot was the token). Undo the Limits bump so a\n"
            "// multi-life box's later hits eject the vanilla goodie count.\n"
            "function SpawnObject(int Index)\n"
            "{\n"
            "    local class<Actor> markerCls, saved;\n"
            "    local int useIdx;\n"
            "\n"
            "    if (!bAPTokenEjected)\n"
            "    {\n"
            "        bAPTokenEjected = True;\n"
            "        Limits.Min -= 1;\n"
            "        Limits.Max -= 1;\n"
            "        if (CheckLocationId > 0)\n"
            "        {\n"
            "            markerCls = class<Actor>(DynamicLoadObject(\n"
            "                \"HPArchipelago.APContainerMarker_\" $ string(CheckLocationId - LOC_BASE), class'Class'));\n"
            "            if (markerCls != None)\n"
            "            {\n"
            "                useIdx = Index;\n"
            "                if (useIdx < 0) { useIdx = 0; }\n"
            "                saved = GoodieToSpawn[useIdx];\n"
            "                GoodieToSpawn[useIdx] = markerCls;\n"
            "                Super.SpawnObject(useIdx);\n"
            "                GoodieToSpawn[useIdx] = saved;\n"
            "                Log(\"[Archipelago] APContainerSpawner: ejected AP token for loc \" $ string(CheckLocationId));\n"
            "                return;\n"
            "            }\n"
            "        }\n"
            "    }\n"
            "    Super.SpawnObject(Index);\n"
            "}\n"
        )
    footer = (
        "\n"
        "defaultproperties\n"
        "{\n"
        "    // Spawn at the exact saved transform on swap (no FindSpot nudge that\n"
        "    // would float a tall box); runtime collision is unaffected.\n"
        "    bCollideWhenPlacing=False\n"
        "}\n"
    )
    return header + decl + body + footer


def emit_container_classes(locations: dict, base_id: int) -> tuple[int, int]:
    """Emit the generated mod classes for containersanity:
      - per-location APContainerMarker_<offset>.uc (baked CheckLocationId) for
        EVERY container row; both the chest eject queue and the spawner goodie
        slot spawn it by name (resolved from CheckLocationId at runtime).
      - one APContainerSpawner_<Leaf>.uc per distinct GenericSpawner leaf (the
        sequential-eject swap target) + APContainerStamp.uc (its cast-chain).
    Chests/cauldrons need NO generated subclass: APCardWatcher injects the baked
    marker into the NATIVE actor's EjectedObjects in place (like the card system),
    which survives hub SaveGame/restore -- a swapped cross-package actor does not.
    Stale generated files (including the obsolete chest swap subclasses + stamp
    from the destroy/respawn design) are removed first so no orphans linger.
    Returns (baked_marker_count, swap_leaf_count)."""
    for old in MOD_CLASSES_DIR.glob("APContainerMarker_*.uc"):
        old.unlink()
    for old in MOD_CLASSES_DIR.glob("APContainerChest_*.uc"):
        old.unlink()
    for old in MOD_CLASSES_DIR.glob("APContainerSpawner_*.uc"):
        old.unlink()
    (MOD_CLASSES_DIR / "APContainerChestStamp.uc").unlink(missing_ok=True)

    marker_n = 0
    swap_leaves: set[str] = set()
    for row in locations.get("containers", []):
        offset = row["id_offset"]
        ap_id = base_id + offset
        (MOD_CLASSES_DIR / f"APContainerMarker_{offset}.uc").write_text(
            "// Auto-generated. Do not edit by hand; regenerate from\n"
            "// data/locations.yaml (containers) via gen_apworld.py.\n"
            f"class APContainerMarker_{offset} extends APContainerMarker;\n"
            "\n"
            "defaultproperties\n"
            "{\n"
            f"    CheckLocationId={ap_id}\n"
            "}\n",
            encoding="utf-8",
        )
        marker_n += 1
        if row["class"].lower() not in CONTAINER_CHEST_CLASSES:
            swap_leaves.add(row["class"])

    for leaf in sorted(swap_leaves):
        (MOD_CLASSES_DIR / f"APContainerSpawner_{leaf}.uc").write_text(
            _spawner_subclass_text(leaf), encoding="utf-8")

    # Spawner stamp: cast-chain that sets CheckLocationId on a freshly-swapped
    # GenericSpawner subclass (the generated subclasses share no base type to
    # cast to from APCardWatcher, so a downcast per leaf does the direct set).
    stamp = [
        "// Auto-generated. Do not edit by hand; regenerate from",
        "// data/locations.yaml (containers) via gen_apworld.py.",
        "class APContainerStamp extends Object;",
        "",
        "// Set CheckLocationId on a freshly-swapped container spawner. Returns",
        "// False if the actor is not a known APContainerSpawner_<Leaf>.",
        "static function bool Stamp(Actor a, int apId)",
        "{",
    ]
    for leaf in sorted(swap_leaves):
        stamp.append(
            f"    if (APContainerSpawner_{leaf}(a) != None)"
            f" {{ APContainerSpawner_{leaf}(a).CheckLocationId = apId; return True; }}")
    stamp += ["    return False;", "}", ""]
    # IsReplaceLeaf: True for swap subclasses whose native goodie is REPLACED by
    # the AP token (single-content jars) rather than dropped alongside it, so
    # SwapContainerSpawner skips the +1 eject-slot bump for them. Only lists
    # replace leaves actually present in this seed's container set.
    stamp += [
        "// True if the spawner's native goodie is REPLACED by the AP token",
        "// (single-content jars: the token drops instead of the bark/mucus).",
        "static function bool IsReplaceLeaf(Actor a)",
        "{",
    ]
    for leaf in sorted(swap_leaves):
        if leaf in CONTAINER_REPLACE_CLASSES:
            stamp.append(
                f"    if (APContainerSpawner_{leaf}(a) != None) return True;")
    stamp += ["    return False;", "}", ""]
    (MOD_CLASSES_DIR / "APContainerStamp.uc").write_text("\n".join(stamp), encoding="utf-8")

    return marker_n, len(swap_leaves)


def build_apworld_zip() -> Path | None:
    """Invoke AP's native `Build APWorlds` Launcher component to package the
    apworld dir into a cross-platform `.apworld` zip. The dev loop's junction
    is Windows-only, so without this Linux players have nothing to install.
    Output lands at `<AP_FRAMEWORK_DIR>/build/apworlds/harry_potter_2_pc.apworld`
    (the Launcher writes it relative to its cwd). Returns the zip path on
    success, None on any failure (so a missing-AP-checkout dev box still gets
    a working .py regen)."""
    launcher = AP_FRAMEWORK_DIR / "Launcher.py"
    if not launcher.is_file():
        print(
            f"WARNING: AP framework not found at {AP_FRAMEWORK_DIR}; skipping "
            f".apworld build. Set HP2_AP_FRAMEWORK_DIR or place the Archipelago "
            f"checkout per DEV_SETUP.md.",
            file=sys.stderr,
        )
        return None
    cmd = [sys.executable, "Launcher.py", "Build APWorlds", APWORLD_GAME_NAME]
    result = subprocess.run(cmd, cwd=AP_FRAMEWORK_DIR, check=False)
    if result.returncode != 0:
        print(
            f"ERROR: 'Build APWorlds' exited {result.returncode}; "
            f"`.apworld` not produced.",
            file=sys.stderr,
        )
        return None
    zip_path = AP_FRAMEWORK_DIR / "build" / "apworlds" / "harry_potter_2_pc.apworld"
    if not zip_path.is_file():
        print(
            f"ERROR: Launcher reported success but {zip_path} is missing.",
            file=sys.stderr,
        )
        return None
    return zip_path


# --- LOCAL ONLY, do not commit -------------------------------------------
def install_apworld(zip_path: Path) -> None:
    """Copy the built apworld into each local custom_worlds dir so the running
    Archipelago picks up the rebuild. Skips dirs that do not exist."""
    import shutil

    for dest_dir in APWORLD_INSTALL_DIRS:
        if not dest_dir.is_dir():
            print(f"  skipped install (no such dir): {dest_dir}")
            continue
        dest = dest_dir / zip_path.name
        shutil.copy2(zip_path, dest)
        print(f"  installed -> {dest}")
# --- end LOCAL ONLY -------------------------------------------------------


def main() -> int:
    items, locations, logic_vanilla, logic_open_castle = load_data()
    try:
        expand_macros(logic_vanilla, items, "logic_vanilla.yaml")
        expand_macros(logic_open_castle, items, "logic_open_castle.yaml")
    except ValueError as e:
        print(f"MACRO ERROR: {e}", file=sys.stderr)
        return 1
    n_secrets = len(locations.get("secrets", []))
    n_stars = len(locations.get("challenge_stars", []))
    n_tradersanity = len(locations.get("tradersanity", []))
    n_containers = len(locations.get("containers", []))
    known_items = collect_known_items(items)
    try:
        validate(items, locations)
        start_v, all_v = validate_logic(logic_vanilla, locations, known_items)
        start_oc, all_oc = validate_logic(logic_open_castle, locations, known_items)
    except ValueError as e:
        print(f"VALIDATION ERROR: {e}", file=sys.stderr)
        return 1
    if start_v != start_oc:
        print(f"VALIDATION ERROR: vanilla start region {start_v!r} != open castle {start_oc!r}", file=sys.stderr)
        return 1
    if all_v != all_oc:
        print(
            f"VALIDATION ERROR: vanilla and open castle region sets differ. "
            f"vanilla-only={sorted(set(all_v) - set(all_oc))}, open-castle-only={sorted(set(all_oc) - set(all_v))}",
            file=sys.stderr,
        )
        return 1
    start_region, all_regions = start_v, all_v

    # Missable-secret dependency projection (vanilla-only). A missable secret
    # is reachable from the starting inventory iff every item in (region entry
    # AND its own requires) is precollected. Compute that item set so HP2World
    # can keep un-satisfiable missable secrets filler-only and never gate a
    # seed on a location the one-way level makes permanently unreachable.
    # Open castle skips this entirely (every level is infinitely replayable).
    secrets_rows = locations.get("secrets", [])
    container_rows = locations.get("containers", [])
    # A region is one-way iff it holds at least one missable secret. Every
    # container in such a region is just as missable in vanilla as those secrets
    # (the level is left behind for good), so it gets the same filler-only
    # treatment. Hub regions (CastleExterior, GrandStaircase, EntryHall) and the
    # replayable challenges have no missable secret, so their containers stay
    # eligible for progression. Region keys the derivation, not level: e.g. the
    # one missable secret in the Grand Staircase level is in DumbledoreStudy, so
    # GrandStaircase (the revisitable hub, with 26 containers) stays eligible.
    missable_regions = {r["region"] for r in secrets_rows if r.get("missable")}
    missable_rows = (
        [r for r in secrets_rows if r.get("missable")]
        + [r for r in container_rows if r.get("region") in missable_regions]
    )

    def _missable_deps(logic: dict) -> dict[str, list[str]]:
        rgns = logic.get("regions") or {}
        locs = logic.get("locations") or {}
        result: dict[str, list[str]] = {}
        for r in missable_rows:
            name = r["name"]
            entry = (rgns.get(r.get("region", "TBD")) or {}).get("entry", "true")
            req = (locs.get(name) or {}).get("requires", "true")
            result[name] = sorted(rule_idents(entry) | rule_idents(req))
        return result

    locations["missable_locations"] = sorted(r["name"] for r in missable_rows)
    locations["missable_location_deps_vanilla"] = _missable_deps(logic_vanilla)

    items_py = APWORLD_DIR / "items.py"
    locations_py = APWORLD_DIR / "locations.py"
    regions_py = APWORLD_DIR / "regions.py"
    rules_py = APWORLD_DIR / "rules.py"
    items_py.write_text(emit_items(items), encoding="utf-8")
    locations_py.write_text(emit_locations(locations, items), encoding="utf-8")
    regions_py.write_text(
        _emit_regions_dual(
            logic_vanilla.get("regions") or {},
            logic_open_castle.get("regions") or {},
            start_region,
            all_regions,
            items,
        ),
        encoding="utf-8",
    )
    rules_py.write_text(emit_rules_dual(logic_vanilla, logic_open_castle, locations, items), encoding="utf-8")

    n_markers = emit_card_markers(items)
    n_registry = emit_location_registry(locations, locations["base_id"])
    n_appearance = emit_card_appearance_registry(locations, locations["base_id"])
    n_cont_marker, n_cont_swap = emit_container_classes(locations, locations["base_id"])

    n_items = sum(len(items.get(c, [])) for c in ("spells", "key_items", "blocker_keys", "equipment", "cards_bronze", "cards_silver", "cards_gold", "filler", "traps"))
    n_locs = sum(len(locations.get(c, [])) for c in LOCATION_CATEGORIES)
    n_regions = len(all_regions)
    n_loc_rules_v = sum(1 for m in (logic_vanilla.get("locations") or {}).values() if (m or {}).get("requires", "true") not in ("true", ""))
    n_loc_rules_oc = sum(1 for m in (logic_open_castle.get("locations") or {}).values() if (m or {}).get("requires", "true") not in ("true", ""))
    print(f"Wrote {items_py} ({n_items} items)")
    print(f"Wrote {locations_py} ({n_locs} locations: {n_secrets} secrets + {n_stars} stars + {n_tradersanity} tradersanity + {n_containers} containers)")
    print(f"Wrote {regions_py} ({n_regions} regions, start={start_region!r})")
    print(f"Wrote {rules_py} (vanilla: {n_loc_rules_v} per-loc rules, {len(logic_vanilla.get('goal') or {})} goal(s); open castle: {n_loc_rules_oc}, {len(logic_open_castle.get('goal') or {})})")
    print(f"Wrote {n_markers} APCardMarker_<X>.uc files in {MOD_CLASSES_DIR}")
    print(f"Wrote APLocationRegistry.uc ({n_registry} secret+star+vendor+container registrations)")
    print(f"Wrote APCardAppearance.uc ({n_appearance} card id registrations)")
    print(f"Containersanity: {n_cont_marker} APContainerMarker_<offset>.uc baked markers + {n_cont_swap} APContainerSpawner_<Leaf>.uc swap subclasses (chests/cauldrons injected in place) in {MOD_CLASSES_DIR}")

    zip_path = build_apworld_zip()
    if zip_path is not None:
        print(f"Built {zip_path} ({zip_path.stat().st_size // 1024} KB)")
        install_apworld(zip_path)  # LOCAL ONLY, do not commit
    return 0


if __name__ == "__main__":
    sys.exit(main())
