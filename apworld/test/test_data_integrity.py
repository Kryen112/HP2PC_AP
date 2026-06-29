"""Static consistency of the generated id maps and the data tables they index.
No multiworld needed; these guard the id space and the cross-references that
create_items / create_regions rely on."""

import unittest

from ..access import _BRONZE_CARD_NAMES, _SILVER_CARD_NAMES
from ..items import (BASE_ID as ITEM_BASE_ID, FILLER_NAMES, ITEM_CLASSIFICATIONS,
                     ITEM_GROUPS, ITEM_NAME_TO_ID, TRAP_NAMES)
from ..locations import (BASE_ID as LOCATION_BASE_ID, LOCATION_GROUPS,
                         LOCATION_NAME_TO_ID, LOCATION_REGIONS,
                         MISSABLE_LOCATION_DEPS_VANILLA, MISSABLE_LOCATIONS)
from ..rules import (LOCATION_RULES_OPEN_CASTLE, LOCATION_RULES_VANILLA,
                     _VANILLA_EXTRA, _VANILLA_ONLY, _VANILLA_OVERRIDE)


class TestDataIntegrity(unittest.TestCase):
    def test_item_ids_unique(self) -> None:
        ids = list(ITEM_NAME_TO_ID.values())
        self.assertEqual(len(ids), len(set(ids)), "duplicate item ids")

    def test_location_ids_unique(self) -> None:
        ids = list(LOCATION_NAME_TO_ID.values())
        self.assertEqual(len(ids), len(set(ids)), "duplicate location ids")

    def test_item_ids_at_or_above_base(self) -> None:
        self.assertTrue(all(v >= ITEM_BASE_ID for v in ITEM_NAME_TO_ID.values()))

    def test_location_ids_at_or_above_base(self) -> None:
        self.assertTrue(all(v >= LOCATION_BASE_ID for v in LOCATION_NAME_TO_ID.values()))

    def test_every_item_has_a_classification(self) -> None:
        missing = set(ITEM_NAME_TO_ID) - set(ITEM_CLASSIFICATIONS)
        self.assertEqual(missing, set(), f"items missing a classification: {sorted(missing)}")

    def test_classifications_reference_real_items(self) -> None:
        extra = set(ITEM_CLASSIFICATIONS) - set(ITEM_NAME_TO_ID)
        self.assertEqual(extra, set(), f"classifications for unknown items: {sorted(extra)}")

    def test_filler_and_traps_are_items(self) -> None:
        for name in FILLER_NAMES + TRAP_NAMES:
            self.assertIn(name, ITEM_NAME_TO_ID, f"{name!r} is not a known item")

    def test_item_groups_reference_real_items(self) -> None:
        for group, names in ITEM_GROUPS.items():
            for name in names:
                self.assertIn(name, ITEM_NAME_TO_ID, f"item group {group!r} -> unknown item {name!r}")

    def test_card_count_helper_lists_match_item_groups(self) -> None:
        # The count helpers (_bronze_cards / _silver_cards) scan these lists,
        # which access.py derives from ITEM_GROUPS. Guard the contract so a
        # future hand-edit can never resilver them out of step with the groups.
        self.assertEqual(_BRONZE_CARD_NAMES, ITEM_GROUPS["Cards (Bronze)"],
                         "_BRONZE_CARD_NAMES drifted from ITEM_GROUPS['Cards (Bronze)']")
        self.assertEqual(_SILVER_CARD_NAMES, ITEM_GROUPS["Cards (Silver)"],
                         "_SILVER_CARD_NAMES drifted from ITEM_GROUPS['Cards (Silver)']")

    def test_filler_and_trap_lists_match_item_groups(self) -> None:
        # FILLER_NAMES / TRAP_NAMES are derived from ITEM_GROUPS; their order is
        # load-bearing (filler-code mapping, reproducible trap picks). Guard both.
        self.assertEqual(FILLER_NAMES, ITEM_GROUPS["Filler"],
                         "FILLER_NAMES drifted from ITEM_GROUPS['Filler']")
        self.assertEqual(TRAP_NAMES, ITEM_GROUPS["Traps"],
                         "TRAP_NAMES drifted from ITEM_GROUPS['Traps']")

    def test_vanilla_rules_derive_from_open_castle(self) -> None:
        # Open castle is the base table. Vanilla = open castle, with _VANILLA_EXTRA
        # ANDed onto existing rules, _VANILLA_OVERRIDE replacing them, and
        # _VANILLA_ONLY adding locations open castle does not gate. Guard the
        # invariants so a stray key cannot silently invent or shadow a rule.
        open_keys = set(LOCATION_RULES_OPEN_CASTLE)
        # EXTRA and OVERRIDE refine existing open-castle rules.
        stray_extra = set(_VANILLA_EXTRA) - open_keys
        self.assertEqual(stray_extra, set(),
                         f"_VANILLA_EXTRA keys not in open castle: {sorted(stray_extra)}")
        stray_override = set(_VANILLA_OVERRIDE) - open_keys
        self.assertEqual(stray_override, set(),
                         f"_VANILLA_OVERRIDE keys not in open castle: {sorted(stray_override)}")
        # ONLY adds locations open castle has no per-location rule for.
        clash_only = set(_VANILLA_ONLY) & open_keys
        self.assertEqual(clash_only, set(),
                         f"_VANILLA_ONLY keys already in open castle: {sorted(clash_only)}")
        # The three delta groups are pairwise disjoint.
        self.assertEqual(set(_VANILLA_EXTRA) & set(_VANILLA_OVERRIDE), set(),
                         "a key is both extended and overridden")
        # Vanilla covers exactly the open-castle keys plus the vanilla-only ones.
        self.assertEqual(set(LOCATION_RULES_VANILLA), open_keys | set(_VANILLA_ONLY),
                         "vanilla keys are not open castle plus the vanilla-only set")

    def test_location_groups_reference_real_locations(self) -> None:
        for loc in LOCATION_GROUPS:
            self.assertIn(loc, LOCATION_NAME_TO_ID, f"location group keyed on unknown location {loc!r}")

    def test_missable_deps_cover_exactly_missable_locations(self) -> None:
        # The deps table is derived per region from MISSABLE_LOCATIONS, so its
        # keys must match exactly. A drift means a missable location lost (or
        # gained) its precollection gate.
        self.assertEqual(set(MISSABLE_LOCATION_DEPS_VANILLA), set(MISSABLE_LOCATIONS),
                         "missable deps keys drifted from MISSABLE_LOCATIONS")

    def test_missable_deps_reference_real_items(self) -> None:
        for loc, deps in MISSABLE_LOCATION_DEPS_VANILLA.items():
            for dep in deps:
                self.assertIn(dep, ITEM_NAME_TO_ID,
                              f"missable dep for {loc!r} -> unknown item {dep!r}")

    def test_every_location_has_a_region(self) -> None:
        missing = set(LOCATION_NAME_TO_ID) - set(LOCATION_REGIONS)
        self.assertEqual(missing, set(), f"locations missing a region: {sorted(missing)}")

    def test_level_completion_ids_are_contiguous(self) -> None:
        # The client's /progress readout range-scans level-completion ids as
        # [base, base + count). That is correct only if the LevelCompletions ids
        # form a gap-free run starting at the base the client scans from
        # (5760700) that no other location intrudes on. Guards both the count
        # (derived in the client) and that range assumption against future drift.
        level_ids = sorted(LOCATION_NAME_TO_ID[n] for n, g in LOCATION_GROUPS.items()
                           if g == "LevelCompletions")
        self.assertTrue(level_ids, "no LevelCompletions locations found")
        self.assertEqual(level_ids[0], 5760700, "level-completion base moved; update the client")
        expected = list(range(level_ids[0], level_ids[0] + len(level_ids)))
        self.assertEqual(level_ids, expected, "level-completion ids are not contiguous")
        intruders = sorted(n for n, i in LOCATION_NAME_TO_ID.items()
                           if level_ids[0] <= i <= level_ids[-1]
                           and LOCATION_GROUPS.get(n) != "LevelCompletions")
        self.assertEqual(intruders, [], f"non-level-completion ids inside the range: {intruders}")
