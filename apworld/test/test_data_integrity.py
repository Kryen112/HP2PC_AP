"""Static consistency of the generated id maps and the data tables they index.
No multiworld needed; these guard the id space and the cross-references that
create_items / create_regions rely on."""

import unittest

from ..items import (BASE_ID as ITEM_BASE_ID, FILLER_NAMES, ITEM_CLASSIFICATIONS,
                     ITEM_GROUPS, ITEM_NAME_TO_ID, TRAP_NAMES)
from ..locations import (BASE_ID as LOCATION_BASE_ID, LOCATION_GROUPS,
                         LOCATION_NAME_TO_ID, LOCATION_REGIONS)


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

    def test_location_groups_reference_real_locations(self) -> None:
        for loc in LOCATION_GROUPS:
            self.assertIn(loc, LOCATION_NAME_TO_ID, f"location group keyed on unknown location {loc!r}")

    def test_every_location_has_a_region(self) -> None:
        missing = set(LOCATION_NAME_TO_ID) - set(LOCATION_REGIONS)
        self.assertEqual(missing, set(), f"locations missing a region: {sorted(missing)}")
