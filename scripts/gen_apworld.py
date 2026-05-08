"""Generates apworld/items.py, locations.py, regions.py, rules.py from data/*.yaml.

Run from the repo root:
    py -3.12 scripts\\gen_apworld.py

After every edit to data/items.yaml, data/locations.yaml, or data/logic.yaml,
re-run this and commit the regenerated apworld/*.py.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = REPO_ROOT / "data"
APWORLD_DIR = REPO_ROOT / "apworld"
MOD_CLASSES_DIR = REPO_ROOT / "mod" / "HPArchipelago" / "Classes"


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


def load_data() -> tuple[dict, dict, dict]:
    items = yaml.safe_load((DATA_DIR / "items.yaml").read_text(encoding="utf-8"))
    locations = yaml.safe_load((DATA_DIR / "locations.yaml").read_text(encoding="utf-8"))
    logic = yaml.safe_load((DATA_DIR / "logic.yaml").read_text(encoding="utf-8"))
    return items, locations, logic


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
        ident = m.group(0)
        if ident in ("true", "True"):
            return "True"
        if ident in ("false", "False"):
            return "False"
        if ident == "TBD":
            return "True"
        if ident not in known_items:
            unknown.append(ident)
        return f"state.has({ident!r}, player)"

    body = re.sub(r"[A-Za-z_][A-Za-z0-9_]*", replace_ident, s)
    body = body.replace("&", " and ").replace("|", " or ")

    if unknown:
        raise ValueError(
            f"{context}: rule {rule_str!r} references unknown item(s): {sorted(set(unknown))}. "
            f"Items must match data/items.yaml `name:` fields."
        )
    return body


def collect_known_items(items: dict) -> set[str]:
    names: set[str] = set()
    for category in ("spells", "key_items", "cards_bronze", "cards_silver", "cards_gold", "filler"):
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
    used_regions = {entry.get("region", "TBD") for category in ("classrooms", "level_completions", "cards") for entry in locations.get(category, [])}
    used_regions.discard("TBD")  # TBD is implicit
    missing = used_regions - set(regions.keys())
    if missing:
        raise ValueError(
            f"locations.yaml references region(s) not defined in logic.yaml `regions:`: {sorted(missing)}"
        )

    # Validate per-location overrides
    location_rules = logic.get("locations") or {}
    location_names_set = {entry["name"] for category in ("classrooms", "level_completions", "cards") for entry in locations.get(category, [])}
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
    for category in ("spells", "key_items", "cards_bronze", "cards_silver", "cards_gold", "filler"):
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
    for category in ("classrooms", "level_completions", "cards"):
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
        '"""AUTO-GENERATED by scripts/gen_apworld.py from data/items.yaml. Do not edit by hand."""',
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
    for entry in items.get("cards_bronze", []):
        # cards inherit classification = useful unless overridden (cards aren't progression in v1).
        e2 = {**entry, "classification": entry.get("classification", "useful")}
        add(e2, None, bronze_names)
        card_class_to_item_name.append((entry["class"], entry["name"]))
    for entry in items.get("cards_silver", []):
        e2 = {**entry, "classification": entry.get("classification", "useful")}
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
    lines.append(f"    'Cards (Bronze)': {bronze_names!r},")
    lines.append(f"    'Cards (Silver)': {silver_names!r},")
    lines.append(f"    'Cards (Gold)': {gold_names!r},")
    lines.append(f"    'Filler': {filler_names!r},")
    lines.append("}")
    lines.append("")
    lines.append(f"FILLER_NAMES: list[str] = {filler_names!r}")
    lines.append("")
    lines.append("# Map UScript card class name → AP item display name. Used by the sidecar")
    lines.append("# when forwarding 'GRANT <classname>' messages to the mod for cards.")
    lines.append("CARD_CLASS_TO_ITEM_NAME: dict[str, str] = {")
    for ucls, iname in card_class_to_item_name:
        lines.append(f"    {ucls!r}: {iname!r},")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def emit_locations(locations: dict) -> str:
    base = locations["base_id"]
    lines: list[str] = [
        '"""AUTO-GENERATED by scripts/gen_apworld.py from data/locations.yaml. Do not edit by hand."""',
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
    for category in ("classrooms", "level_completions", "cards"):
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
    lines.append("# Map UScript card class name → AP location name. Used by the sidecar to")
    lines.append("# resolve a game CHECK to the right AP location for LocationChecks.")
    lines.append("CARD_CLASS_TO_LOCATION_NAME: dict[str, str] = {")
    for ucls, loc_name in card_class_to_loc:
        lines.append(f"    {ucls!r}: {loc_name!r},")
    lines.append("}")
    lines.append("")
    lines.append("# Map game-side card Id (the UScript WC*.uc default Id property) → AP")
    lines.append("# location name. Sidecar receives 'CHECK <int>' from the mod and uses")
    lines.append("# this to find the AP location to send LocationChecks for.")
    lines.append("CARD_GAME_ID_TO_LOCATION_NAME: dict[int, str] = {")
    for game_id, loc_name in sorted(card_game_id_to_loc_name):
        lines.append(f"    {game_id}: {loc_name!r},")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def emit_regions(logic: dict, start_region: str, all_regions: list[str]) -> str:
    """Emit apworld/regions.py: REGION_NAMES, START_REGION, REGION_ENTRY_RULES."""
    regions = logic.get("regions") or {}
    known_items = set()  # already validated; pass empty so unknown-check is skipped here
    # We re-parse rules but with the items set we get from the logic-validated state.
    # Caller has already validated, so passing an unrestricted set just for emission:
    return _emit_regions_impl(regions, start_region, all_regions)


def _emit_regions_impl(regions: dict, start_region: str, all_regions: list[str]) -> str:
    lines: list[str] = [
        '"""AUTO-GENERATED by scripts/gen_apworld.py from data/logic.yaml. Do not edit by hand."""',
        "",
        "from typing import Callable",
        "",
        "from BaseClasses import CollectionState",
        "",
        f"START_REGION: str = {start_region!r}",
        "",
        f"REGION_NAMES: list[str] = {all_regions!r}",
        "",
        "# region_name -> rule(state, player) -> bool. The rule is the requirement to",
        "# enter the region from the start region (Menu) in the open-hub v1 model. Any",
        "# region not listed here is considered always-reachable (entry rule = True).",
        "REGION_ENTRY_RULES: dict[str, Callable[[CollectionState, int], bool]] = {",
    ]
    for region_name in sorted(regions.keys()):
        meta = regions[region_name] or {}
        if region_name == start_region:
            continue  # start region has no entry rule (you're already there)
        rule_str = meta.get("entry", "true")
        # Re-parse with empty known set since validate_logic already checked.
        # Use a fake set that allows anything — we need to extract item names.
        body = _emit_rule_body(rule_str)
        lines.append(f"    {region_name!r}: lambda state, player: {body},")
    lines.append("}")
    lines.append("")
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
        ident = m.group(0)
        if ident in ("true", "True", "TBD"):
            return "True"
        if ident in ("false", "False"):
            return "False"
        return f"state.has({ident!r}, player)"

    body = re.sub(r"[A-Za-z_][A-Za-z0-9_]*", replace_ident, s)
    return body.replace("&", " and ").replace("|", " or ")


def emit_rules(logic: dict, locations: dict) -> str:
    """Emit apworld/rules.py: LOCATION_RULES, GOAL_REQUIREMENTS."""
    location_rules = logic.get("locations") or {}
    goal = logic.get("goal") or {}

    # locations.yaml is the authoritative source for location->region; logic.yaml
    # entries with `region:` should match. Per-location `requires:` is the only
    # thing we emit (a rule on top of region entry).
    lines: list[str] = [
        '"""AUTO-GENERATED by scripts/gen_apworld.py from data/logic.yaml. Do not edit by hand."""',
        "",
        "from typing import Callable",
        "",
        "from BaseClasses import CollectionState",
        "",
        "# Per-location additional rules. Location is reachable iff its region's",
        "# entry rule passes AND this rule passes. Locations not listed here have no",
        "# extra requirement (the region's entry rule alone gates reachability).",
        "LOCATION_RULES: dict[str, Callable[[CollectionState, int], bool]] = {",
    ]
    for loc_name in sorted(location_rules.keys()):
        meta = location_rules[loc_name] or {}
        rule_str = meta.get("requires", "true")
        # Skip emitting rules that are trivially True (no override).
        body = _emit_rule_body(rule_str)
        if body == "True":
            continue
        lines.append(f"    {loc_name!r}: lambda state, player: {body},")
    lines.append("}")
    lines.append("")
    lines.append("# goal_name -> list of location names that must be reachable for victory.")
    lines.append("# Player picks one via the YAML `goal:` option (default `basilisk` for v1).")
    lines.append("GOAL_REQUIREMENTS: dict[str, list[str]] = {")
    for goal_name in sorted(goal.keys()):
        meta = goal[goal_name] or {}
        reqs = meta.get("requires_completed", [])
        lines.append(f"    {goal_name!r}: {reqs!r},")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def emit_card_markers() -> int:
    """Emit one APCardMarker_<ClassName>.uc per card in CARD_GAME_ID_TO_CLASS.

    Each subclass extends APCardMarker (in mod/HPArchipelago/Classes/APCardMarker.uc,
    hand-authored) and sets `CardLocationId` to the card's game-side id. Vanilla
    chests/cauldrons hold a class reference in EjectedObjects; APGameInfo.InitGame
    swaps card classes for the corresponding marker subclass at every level entry.

    Returns the number of marker files written.
    """
    # Clean any previously-generated APCardMarker_*.uc files to avoid stale entries
    # if data/items.yaml ever shrinks.
    for stale in MOD_CLASSES_DIR.glob("APCardMarker_*.uc"):
        stale.unlink()

    written = 0
    for game_id, ucls in sorted(CARD_GAME_ID_TO_CLASS.items()):
        path = MOD_CLASSES_DIR / f"APCardMarker_{ucls}.uc"
        path.write_text(
            "// AUTO-GENERATED by scripts/gen_apworld.py from data/items.yaml.\n"
            "// Do not edit by hand. Re-run the generator after editing items.yaml.\n"
            f"class APCardMarker_{ucls} extends APCardMarker;\n"
            "\n"
            "defaultproperties\n"
            "{\n"
            f"    CardLocationId={game_id}\n"
            "}\n",
            encoding="utf-8",
        )
        written += 1
    return written


def main() -> int:
    items, locations, logic = load_data()
    known_items = collect_known_items(items)
    try:
        validate(items, locations)
        start_region, all_regions = validate_logic(logic, locations, known_items)
    except ValueError as e:
        print(f"VALIDATION ERROR: {e}", file=sys.stderr)
        return 1

    items_py = APWORLD_DIR / "items.py"
    locations_py = APWORLD_DIR / "locations.py"
    regions_py = APWORLD_DIR / "regions.py"
    rules_py = APWORLD_DIR / "rules.py"
    items_py.write_text(emit_items(items), encoding="utf-8")
    locations_py.write_text(emit_locations(locations), encoding="utf-8")
    regions_py.write_text(_emit_regions_impl(logic.get("regions") or {}, start_region, all_regions), encoding="utf-8")
    rules_py.write_text(emit_rules(logic, locations), encoding="utf-8")

    n_markers = emit_card_markers()

    n_items = sum(len(items.get(c, [])) for c in ("spells", "key_items", "cards_bronze", "cards_silver", "cards_gold", "filler"))
    n_locs = sum(len(locations.get(c, [])) for c in ("classrooms", "level_completions", "cards"))
    n_regions = len(all_regions)
    n_loc_rules = sum(1 for m in (logic.get("locations") or {}).values() if (m or {}).get("requires", "true") not in ("true", ""))
    print(f"Wrote {items_py} ({n_items} items)")
    print(f"Wrote {locations_py} ({n_locs} locations)")
    print(f"Wrote {regions_py} ({n_regions} regions, start={start_region!r})")
    print(f"Wrote {rules_py} ({n_loc_rules} per-location overrides, {len(logic.get('goal') or {})} goal(s))")
    print(f"Wrote {n_markers} APCardMarker_<X>.uc files in {MOD_CLASSES_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
