"""Generates apworld/items.py, locations.py, regions.py, rules.py from data/*.yaml.

Run from the repo root:
    py -3.12 gen_apworld.py

After every edit to data/items.yaml, data/locations.yaml, or data/logic.yaml,
re-run this and commit the regenerated apworld/*.py.
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
    "secrets",
    "challenge_stars",
    "level_completions",
)




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


# Per-card vendor metadata, harvested from each WCXxx.uc default in
# HP2UScriptDecompile/HGame/Classes/WizardCards/. Stable across game versions
# (extracted once 2026-05-12). Used by emit_card_markers to write the
# corresponding fields onto each generated APCardMarker_<X> subclass so
# APCardWatcher.AssignMarkersToVendors can assign markers into vendor stock —
# vanilla AssignVendorCards reads slotClass.Default.Id (=200 sentinel on our
# markers) and slotClass.Default.bVendorsCanSell (=False inherited from
# WizardCardIcon base), so without these copied defaults vanilla skips every
# marker and our cards never reach vendor inventory.
#
# Tuple is (bVendorsCanSell, strVendorOwnedAfterGState, tier).
# Tier is "Bronze"/"Silver"/"Gold" — derived from the parent class
# (BronzeCards/SilverCards/Goldcards). All 11 gold cards are non-sellable
# (set rewards). 59 of 101 cards are sellable in vanilla.
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
    logic_bingo = yaml.safe_load((DATA_DIR / "logic_bingo.yaml").read_text(encoding="utf-8"))
    return items, locations, logic_vanilla, logic_bingo


SILVER_CARDS_MACRO = "@all_silver_cards"


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

    `@all_silver_cards` expands to the parenthesised AND of every
    cards_silver item name in items.yaml. The GoldCardRoom 40-silver gate
    is then a single source of truth — the items.yaml card tier
    classification — instead of a hand-maintained name chain duplicated
    across logic_vanilla.yaml and logic_bingo.yaml. Expanding before
    validation means parse_rule still checks every expanded name, so a
    silver-tier typo in items.yaml is caught here too.
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
    leftover = sorted({
        m.group(0)
        for meta, key in slots
        for m in re.finditer(r"@[A-Za-z_][A-Za-z0-9_]*", meta[key])
    })
    if leftover:
        raise ValueError(
            f"{context}: unknown rule macro(s) {leftover}; only {SILVER_CARDS_MACRO} is defined"
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
    for category in ("spells", "key_items", "bingo_keys", "cards_bronze", "cards_silver", "cards_gold", "filler"):
        for entry in items.get(category, []):
            names.add(entry["name"])
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
    for category in ("spells", "key_items", "bingo_keys", "equipment", "cards_bronze", "cards_silver", "cards_gold", "filler"):
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
    bingo_keys_names: list[str] = []
    equipment_names: list[str] = []
    bronze_names: list[str] = []
    silver_names: list[str] = []
    gold_names: list[str] = []
    filler_names: list[str] = []
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
    for entry in items.get("bingo_keys", []):
        add(entry, None, bingo_keys_names)
    for entry in items.get("equipment", []):
        # Fred/George vendor items. Paired with `enable_quidditch_upgrades`:
        # gen_apworld emits them into ITEM_NAME_TO_ID unconditionally (stable
        # AP id space across toggle flips) but HP2World.create_items skips
        # them when the toggle is off, alongside the matching locations.
        add(entry, None, equipment_names)
    for entry in items.get("cards_bronze", []):
        # cards inherit classification = useful unless overridden (cards aren't progression in v1).
        e2 = {**entry, "classification": entry.get("classification", "useful")}
        add(e2, None, bronze_names)
        card_class_to_item_name.append((entry["class"], entry["name"]))
    for entry in items.get("cards_silver", []):
        # Silvers default to progression_skip_balancing (not useful). The
        # HP2World.set_rules silver-gate on GoldCardRoom locations requires
        # state.has(silver, player) to return True for every silver, and
        # state.has only tracks items in `prog_items` — advancement-flagged
        # items (progression OR progression_skip_balancing). Useful-tier
        # items skip prog_items so the gate could never be satisfied even
        # after all 40 silvers were collected. skip_balancing variant keeps
        # silvers out of progression rebalancing (they aren't strictly
        # required for the basilisk goal) while still flagging them as
        # advancement so state.has + the accessibility sweep both work.
        e2 = {**entry, "classification": entry.get("classification", "progression_skip_balancing")}
        add(e2, None, silver_names)
        card_class_to_item_name.append((entry["class"], entry["name"]))
    for entry in items.get("cards_gold", []):
        e2 = {**entry, "classification": entry.get("classification", "useful")}
        add(e2, None, gold_names)
        card_class_to_item_name.append((entry["class"], entry["name"]))
    for entry in items.get("filler", []):
        add(entry, None, filler_names)

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
    lines.append(f"    'Bingo Keys': {bingo_keys_names!r},")
    lines.append(f"    'Equipment': {equipment_names!r},")
    lines.append(f"    'Cards (Bronze)': {bronze_names!r},")
    lines.append(f"    'Cards (Silver)': {silver_names!r},")
    lines.append(f"    'Cards (Gold)': {gold_names!r},")
    lines.append(f"    'Filler': {filler_names!r},")
    lines.append("}")
    lines.append("")
    lines.append(f"FILLER_NAMES: list[str] = {filler_names!r}")
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
    # spell may be placed here in bingo). validate() already enforces
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
    lines.append("# a vanilla concept (bingo's open castle replays every level), so")
    lines.append("# there is no bingo dependency table. A subset of the precollected")
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
    regions_bingo: dict,
    start_region: str,
    all_regions: list[str],
) -> str:
    """Emit apworld/regions.py with both vanilla and bingo entry-rule tables."""
    lines: list[str] = [
        '"""Auto-generated. Do not edit by hand; regenerate from data/logic_vanilla.yaml + data/logic_bingo.yaml."""',
        "",
        "from typing import Callable",
        "",
        "from BaseClasses import CollectionState",
        "",
        f"START_REGION: str = {start_region!r}",
        "",
        f"REGION_NAMES: list[str] = {all_regions!r}",
        "",
        "# region_name -> rule(state, player) -> bool. Mode-dependent: HP2World",
        "# selects vanilla or bingo at gen time via self.options.game_mode.",
    ]
    lines += _emit_region_table("REGION_ENTRY_RULES_VANILLA", regions_vanilla, start_region)
    lines += _emit_region_table("REGION_ENTRY_RULES_BINGO", regions_bingo, start_region)
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


def emit_rules_dual(logic_vanilla: dict, logic_bingo: dict, locations: dict) -> str:
    """Emit apworld/rules.py with both vanilla and bingo rule tables."""
    lines: list[str] = [
        '"""Auto-generated. Do not edit by hand; regenerate from data/logic_vanilla.yaml + data/logic_bingo.yaml."""',
        "",
        "from typing import Callable",
        "",
        "from BaseClasses import CollectionState",
        "",
        "# Per-location additional rules (on top of region entry).",
        "# Mode-dependent: HP2World selects vanilla or bingo at gen time.",
    ]
    lines += _emit_location_table("LOCATION_RULES_VANILLA", logic_vanilla.get("locations") or {})
    lines += _emit_location_table("LOCATION_RULES_BINGO", logic_bingo.get("locations") or {})

    lines.append("# goal_name -> direct item/logic rule for victory generation.")
    lines.append("# Vanilla only: bingo sets completion_condition from _bingo_complete")
    lines.append("# (cards/spells has-counts + level-completion reachability), so it")
    lines.append("# needs no goal-rule table. Runtime completion still comes from the")
    lines.append("# game-side GOAL_COMPLETE signal.")
    lines += _emit_goal_rule_table("GOAL_RULES_VANILLA", logic_vanilla.get("goal") or {})

    lines.append("# Optional goal_name -> location names that must be reachable")
    lines.append("# for victory. Vanilla only, for the same reason as the goal-rule")
    lines.append("# table above (bingo uses _bingo_complete).")
    lines += _emit_goal_locations_table("GOAL_LOCATION_REQUIREMENTS_VANILLA", logic_vanilla.get("goal") or {})
    return "\n".join(lines)


def emit_location_registry(locations: dict, base_id: int) -> int:
    """Emit mod/HPArchipelago/Classes/APLocationRegistry.uc.

    Two static lookups: secret-marker (LevelName, MarkerName) → AP location id
    and star-marker (LevelName, MarkerName) → AP location id. Returns 0 if a
    given marker isn't registered (e.g. star in a non-challenge level, secret
    in a level we haven't catalogued). The watcher uses these to fire
    CHECK_LOCID on the correct AP location when bFound flips / star vanishes.
    Level names are normalised via Caps() in both the emitter and the watcher
    so case differences between Level.Outer.Name and the catalogue don't bite.
    Returns the total number of registered (level, marker) pairs.
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
        "// data/locations.yaml (secrets + challenge_stars sections).",
        "class APLocationRegistry extends Object;",
        "",
    ]
    lines += emit_lookup("GetSecretLocationId", secret_entries)
    lines.append("")
    lines += emit_lookup("GetStarLocationId", star_entries)
    lines.append("")
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(secret_entries) + len(star_entries)


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

    # Clean any previously-generated APCardMarker_WC*.uc files to avoid stale
    # entries if data/items.yaml ever shrinks. Scoped to the WC prefix so the
    # cleanup never sweeps up hand-authored APCardMarker_* subclasses (the
    # generated set is always WC-prefixed because every card class in
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
    items, locations, logic_vanilla, logic_bingo = load_data()
    try:
        expand_macros(logic_vanilla, items, "logic_vanilla.yaml")
        expand_macros(logic_bingo, items, "logic_bingo.yaml")
    except ValueError as e:
        print(f"MACRO ERROR: {e}", file=sys.stderr)
        return 1
    n_secrets = len(locations.get("secrets", []))
    n_stars = len(locations.get("challenge_stars", []))
    known_items = collect_known_items(items)
    try:
        validate(items, locations)
        start_v, all_v = validate_logic(logic_vanilla, locations, known_items)
        start_b, all_b = validate_logic(logic_bingo, locations, known_items)
    except ValueError as e:
        print(f"VALIDATION ERROR: {e}", file=sys.stderr)
        return 1
    if start_v != start_b:
        print(f"VALIDATION ERROR: vanilla start region {start_v!r} != bingo {start_b!r}", file=sys.stderr)
        return 1
    if all_v != all_b:
        print(
            f"VALIDATION ERROR: vanilla and bingo region sets differ. "
            f"vanilla-only={sorted(set(all_v) - set(all_b))}, bingo-only={sorted(set(all_b) - set(all_v))}",
            file=sys.stderr,
        )
        return 1
    start_region, all_regions = start_v, all_v

    # Missable-secret dependency projection (vanilla-only). A missable secret
    # is reachable from the starting inventory iff every item in (region entry
    # AND its own requires) is precollected. Compute that item set so HP2World
    # can keep un-satisfiable missable secrets filler-only and never gate a
    # seed on a location the one-way level makes permanently unreachable.
    # Bingo skips this entirely (every level is infinitely replayable).
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
            logic_bingo.get("regions") or {},
            start_region,
            all_regions,
        ),
        encoding="utf-8",
    )
    rules_py.write_text(emit_rules_dual(logic_vanilla, logic_bingo, locations), encoding="utf-8")

    n_markers = emit_card_markers(items)
    n_registry = emit_location_registry(locations, locations["base_id"])

    n_items = sum(len(items.get(c, [])) for c in ("spells", "key_items", "bingo_keys", "equipment", "cards_bronze", "cards_silver", "cards_gold", "filler"))
    n_locs = sum(len(locations.get(c, [])) for c in LOCATION_CATEGORIES)
    n_regions = len(all_regions)
    n_loc_rules_v = sum(1 for m in (logic_vanilla.get("locations") or {}).values() if (m or {}).get("requires", "true") not in ("true", ""))
    n_loc_rules_b = sum(1 for m in (logic_bingo.get("locations") or {}).values() if (m or {}).get("requires", "true") not in ("true", ""))
    print(f"Wrote {items_py} ({n_items} items)")
    print(f"Wrote {locations_py} ({n_locs} locations: {n_secrets} secrets + {n_stars} stars)")
    print(f"Wrote {regions_py} ({n_regions} regions, start={start_region!r})")
    print(f"Wrote {rules_py} (vanilla: {n_loc_rules_v} per-loc rules, {len(logic_vanilla.get('goal') or {})} goal(s); bingo: {n_loc_rules_b}, {len(logic_bingo.get('goal') or {})})")
    print(f"Wrote {n_markers} APCardMarker_<X>.uc files in {MOD_CLASSES_DIR}")
    print(f"Wrote APLocationRegistry.uc ({n_registry} secret+star registrations)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
