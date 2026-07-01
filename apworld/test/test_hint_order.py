"""slot_data['hint_order'] feeds the client's /hint command: per kind, this
slot's own spell / key / card items ordered by the sphere their placement opens
in. The command offers the earliest such item the player has not collected."""

from .. import CARD_ITEM_NAMES
from ..items import ITEM_GROUPS
from .bases import HP2TestBase


class _HintOrderChecks:
    """Shared assertions, mixed into a concrete mode-specific test case. Not a
    test case itself, so unittest never runs it with default options."""

    run_default_tests = False

    def _placed_by_kind(self) -> dict:
        kinds = {
            "spell": set(ITEM_GROUPS["Spells"]),
            "key": set(ITEM_GROUPS["Blocker Keys"]),
            "card": set(CARD_ITEM_NAMES),
        }
        placed = {kind: set() for kind in kinds}
        for location in self.multiworld.get_locations():
            item = location.item
            if item is None or item.player != self.player:
                continue
            for kind, names in kinds.items():
                if item.name in names:
                    placed[kind].add(item.name)
                    break
        return placed

    def _sphere_of_name(self) -> dict:
        sphere_index = {}
        for index, sphere in enumerate(self.multiworld.get_spheres()):
            for location in sphere:
                sphere_index[location] = index
        name_to_sphere = {}
        for location in self.multiworld.get_locations():
            item = location.item
            if item is not None and item.player == self.player:
                name_to_sphere[item.name] = sphere_index.get(location)
        return name_to_sphere

    def test_hint_order_present_and_shaped(self) -> None:
        order = self.world.fill_slot_data()["hint_order"]
        self.assertEqual(set(order), {"spell", "key", "card"})
        for names in order.values():
            self.assertIsInstance(names, list)
            self.assertTrue(all(isinstance(name, str) for name in names))
            self.assertEqual(len(names), len(set(names)))

    def test_hint_order_categories_stay_pure(self) -> None:
        order = self.world.fill_slot_data()["hint_order"]
        self.assertTrue(set(order["spell"]) <= set(ITEM_GROUPS["Spells"]))
        self.assertTrue(set(order["key"]) <= set(ITEM_GROUPS["Blocker Keys"]))
        self.assertTrue(set(order["card"]) <= set(CARD_ITEM_NAMES))

    def test_hint_order_covers_this_slots_placed_items(self) -> None:
        order = self.world.fill_slot_data()["hint_order"]
        placed = self._placed_by_kind()
        for kind in placed:
            self.assertEqual(set(order[kind]), placed[kind])

    def test_hint_order_is_sphere_sorted(self) -> None:
        order = self.world.fill_slot_data()["hint_order"]
        name_to_sphere = self._sphere_of_name()
        for names in order.values():
            spheres = [name_to_sphere[name] for name in names]
            spheres = [sphere for sphere in spheres if sphere is not None]
            self.assertEqual(spheres, sorted(spheres))


class TestHintOrderVanilla(_HintOrderChecks, HP2TestBase):
    options = {"game_mode": "vanilla"}


class TestHintOrderOpenCastle(_HintOrderChecks, HP2TestBase):
    options = {"game_mode": "open_castle"}
