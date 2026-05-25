"""Generate apworld/{items,locations,regions,rules}.py and the mod's
APLocationRegistry/APCardAppearance/APCardMarker_*.uc from data/*.yaml.

Run from the repo root:
    py -3.12 gen_apworld.py

Re-run after editing any data/*.yaml and commit the regenerated files.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parent
DATA_DIR = REPO_ROOT / "data"
APWORLD_DIR = REPO_ROOT / "apworld"
MOD_CLASSES_DIR = REPO_ROOT / "mod" / "HPArchipelago" / "Classes"

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
)

# Non-card-location dedupe window. Mirrors `NONCARD_LOC_WINDOW` in
# mod/HPArchipelago/Classes/APCardWatcher.uc — the two MUST hold the same
# value. A non-card location whose id_offset >= this falls outside the mod's
# NonCardLocationChecked[] array, so its dedupe is silently skipped and the
# check re-fires on level re-entry / save-load. Card-location and item offsets
# are deliberately NOT gated. See plans/ID_BAND_LEDGER.md.
NONCARD_LOC_WINDOW = 1024
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
# Add cards here as they're discovered during playtest. The check is exact-name
# against the WC class, e.g. "WCToothill".
FLOATING_CARDS: set[str] = {
    "WCToothill",  # Grand Staircase — floats at the top, requires Spongify-jump.
}


def load_data() -> tuple[dict, dict, dict, dict]:
    items = yaml.safe_load((DATA_DIR / "items.yaml").read_text(encoding="utf-8"))
    locations = yaml.safe_load((DATA_DIR / "locations.yaml").read_text(encoding="utf-8"))
    logic_vanilla = yaml.safe_load((DATA_DIR / "logic_vanilla.yaml").read_text(encoding="utf-8"))
    logic_open_castle = yaml.safe_load((DATA_DIR / "logic_open_castle.yaml").read_text(encoding="utf-8"))
    return items, locations, logic_vanilla, logic_open_castle


SILVER_CARDS_MACRO = "@all_silver_cards"
# Open-castle Gold Card Room gate. The in-game door (CardLockTrigger in
# Grandstaircase_hub.unr) only wires CardLock1 + CardLock2, so it fully opens
# at 20 silvers (Lock1@10 + Lock2@20) — not 40. Open castle has no card-
# collection arc forcing the player toward 40 silvers, so the AP logic must
# match physical reachability or UT hides the room from players already
# standing in it. Vanilla logic keeps @all_silver_cards (matches the "collect
# them all" expectation of that mode). Expansion sentinel is a bare ident the
# rule grammar accepts; _emit_rule_body special-cases it.
SILVER_AT_LEAST_20_MACRO = "@silver_cards_at_least_20"
SILVER_AT_LEAST_20_SENTINEL = "_HP2_silver_cards_at_least_20_"
SILVER_AT_LEAST_20_THRESHOLD = 20


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

    `@all_silver_cards` expands to the parenthesised AND of every cards_silver
    item name in items.yaml — single source of truth for the items.yaml card
    tier classification, so a silver-tier typo gets caught here too.

    `@silver_cards_at_least_20` expands to a bare-ident sentinel that
    `_emit_rule_body` rewrites to `state.has_from_list_unique(SILVER_CARD_NAMES,
    player, 20)`. Used only by the open-castle GoldCardRoom region (the
    physical in-game door opens at 20 silvers, not 40 — see comment on
    SILVER_AT_LEAST_20_MACRO).
    """
    silver_names = [e["name"] for e in items.get("cards_silver", [])]
    if not silver_names:
        raise ValueError(
            f"{context}: items.yaml has no cards_silver to expand {SILVER_CARDS_MACRO}"
        )
    chain = "(" + " & ".join(f"'{n}'" for n in silver_names) + ")"
    slots = _rule_string_slots(logic)
    for meta, key in slots:
        meta[key] = meta[key].replace(SILVER_CARDS_MACRO, chain)
        meta[key] = meta[key].replace(SILVER_AT_LEAST_20_MACRO, SILVER_AT_LEAST_20_SENTINEL)
    leftover = sorted({
        m.group(0)
        for meta, key in slots
        for m in re.finditer(r"@[A-Za-z_][A-Za-z0-9_]*", meta[key])
    })
    if leftover:
        raise ValueError(
            f"{context}: unknown rule macro(s) {leftover}; defined: "
            f"{SILVER_CARDS_MACRO}, {SILVER_AT_LEAST_20_MACRO}"
        )


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
        # Lenient: treat TBD as always-reachable so seeds gen during playtest.
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
        out.add(ident)
    return out


def collect_known_items(items: dict) -> set[str]:
    names: set[str] = set()
    for category in ("spells", "key_items", "blocker_keys", "cards_bronze", "cards_silver", "cards_gold", "filler", "traps"):
        for entry in items.get(category, []):
            names.add(entry["name"])
    # Bare-ident sentinels emitted by expand_macros. parse_rule must accept
    # them (else validation fails on the legitimate use), and _emit_rule_body
    # rewrites them to non-state.has() Python expressions.
    names.add(SILVER_AT_LEAST_20_SENTINEL)
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
    # (allow "TBD" as a valid placeholder so playtest can iterate).
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
                    f"in-window band and record it in plans/ID_BAND_LEDGER.md."
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
        # game-side reward — only silvers feed StatusItemLock1..4 / the Gold
        # Card Room — and no logic_*.yaml rule references a gold card). Open
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
    # the filler delta between FILLER_NAMES and TRAP_NAMES per the
    # enable_traps / trap_fill_percent options.
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

    # Gold-card vault location set, derived from the items.yaml gold tier
    # classification (cards_gold) via the card_class -> location map. Single
    # source of truth for the GoldCardRoom placement exclusions in
    # HP2World.set_rules (no silver may be placed here in any mode; no key or
    # spell may be placed here in open castle). validate() already enforces
    # items-vs-locations card-class parity, so every gold class resolves.
    gold_loc_names: list[str] = []
    for entry in items.get("cards_gold", []):
        ucls = entry["class"]
        loc_name = class_to_loc.get(ucls)
        if loc_name is None:
            raise ValueError(
                f"cards_gold class {ucls!r} has no card location in locations.yaml"
            )
        gold_loc_names.append(loc_name)
    lines.append("GOLD_CARD_ROOM_LOCATIONS: frozenset = frozenset({")
    for n in sorted(gold_loc_names):
        lines.append(f"    {n!r},")
    lines.append("})")
    lines.append("")
    lines.append("# Secrets in one-way (un-replayable) levels: permanently lost once")
    lines.append("# the level is left behind. HP2World keeps these filler-only unless")
    lines.append("# allow_secrets_progression is set AND every item they depend on is")
    lines.append("# precollected (so the player is guaranteed to hold it while passing")
    lines.append("# through the level the one time it is reachable).")
    lines.append("MISSABLE_SECRETS: frozenset = frozenset({")
    for n in locations.get("missable_secrets", []):
        lines.append(f"    {n!r},")
    lines.append("})")
    lines.append("")
    lines.append("# Item names appearing in (region entry AND location requires)")
    lines.append("# for each missable secret. Vanilla-only: the missable system is")
    lines.append("# a vanilla concept (open castle replays every level), so there is")
    lines.append("# no open castle dependency table. A subset of the precollected")
    lines.append("# starting inventory means the secret is reachable from the start.")
    lines.append("MISSABLE_SECRET_DEPS_VANILLA: dict[str, list[str]] = {")
    for n, deps in locations.get("missable_secret_deps_vanilla", {}).items():
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
        "# Silver card item names — referenced by lambdas that gate on the",
        "# open-castle Gold Card Room (20-of-40 silvers, matching the in-game",
        "# CardLockTrigger that only wires Lock1+Lock2). Sourced from",
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
    """Convert rule string to lambda-body Python expression. No validation here —
    caller has already validated via parse_rule(). TBD compiles to True (lenient)."""
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
        if ident == SILVER_AT_LEAST_20_SENTINEL:
            return (
                f"state.has_from_list_unique(_SILVER_CARD_NAMES, player, "
                f"{SILVER_AT_LEAST_20_THRESHOLD})"
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
        '"""Auto-generated. Do not edit by hand; regenerate from data/logic_vanilla.yaml + data/logic_open_castle.yaml."""',
        "",
        "from typing import Callable",
        "",
        "from BaseClasses import CollectionState",
        "",
        "# Silver card item names — referenced by per-location lambdas that gate",
        "# on the open-castle Gold Card Room (20-of-40 silvers, matching the",
        "# in-game CardLockTrigger that only wires Lock1+Lock2). Sourced from",
        "# items.yaml.cards_silver at gen time so it can never drift.",
        f"_SILVER_CARD_NAMES: list[str] = {silver_names!r}",
        "",
        "# Per-location additional rules (on top of region entry).",
        "# Mode-dependent: HP2World selects vanilla or open castle at gen time.",
    ]
    lines += _emit_location_table("LOCATION_RULES_VANILLA", logic_vanilla.get("locations") or {})
    lines += _emit_location_table("LOCATION_RULES_OPEN_CASTLE", logic_open_castle.get("locations") or {})

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

    def expand_levels(level_field: Any) -> list[str]:
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
        "// data/locations.yaml (secrets + challenge_stars + tradersanity sections).",
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
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(secret_entries) + len(star_entries) + len(vendor_entries)


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
    they don't inherit a soundPickup default — we set it here.

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

    def _missable_deps(logic: dict) -> dict[str, list[str]]:
        rgns = logic.get("regions") or {}
        locs = logic.get("locations") or {}
        result: dict[str, list[str]] = {}
        for r in secrets_rows:
            if not r.get("missable"):
                continue
            name = r["name"]
            entry = (rgns.get(r.get("region", "TBD")) or {}).get("entry", "true")
            req = (locs.get(name) or {}).get("requires", "true")
            result[name] = sorted(rule_idents(entry) | rule_idents(req))
        return result

    locations["missable_secrets"] = sorted(
        r["name"] for r in secrets_rows if r.get("missable")
    )
    locations["missable_secret_deps_vanilla"] = _missable_deps(logic_vanilla)

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

    n_items = sum(len(items.get(c, [])) for c in ("spells", "key_items", "blocker_keys", "equipment", "cards_bronze", "cards_silver", "cards_gold", "filler", "traps"))
    n_locs = sum(len(locations.get(c, [])) for c in LOCATION_CATEGORIES)
    n_regions = len(all_regions)
    n_loc_rules_v = sum(1 for m in (logic_vanilla.get("locations") or {}).values() if (m or {}).get("requires", "true") not in ("true", ""))
    n_loc_rules_oc = sum(1 for m in (logic_open_castle.get("locations") or {}).values() if (m or {}).get("requires", "true") not in ("true", ""))
    print(f"Wrote {items_py} ({n_items} items)")
    print(f"Wrote {locations_py} ({n_locs} locations: {n_secrets} secrets + {n_stars} stars + {n_tradersanity} tradersanity)")
    print(f"Wrote {regions_py} ({n_regions} regions, start={start_region!r})")
    print(f"Wrote {rules_py} (vanilla: {n_loc_rules_v} per-loc rules, {len(logic_vanilla.get('goal') or {})} goal(s); open castle: {n_loc_rules_oc}, {len(logic_open_castle.get('goal') or {})})")
    print(f"Wrote {n_markers} APCardMarker_<X>.uc files in {MOD_CLASSES_DIR}")
    print(f"Wrote APLocationRegistry.uc ({n_registry} secret+star+vendor registrations)")
    print(f"Wrote APCardAppearance.uc ({n_appearance} card id registrations)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
