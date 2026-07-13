"""slot_data['hint_order'] feeds the client's /hint command: per kind, this
slot's own spell / key / card items ordered by the sphere their placement opens
in. The command offers the earliest such item the player has not collected.
The Progressive Level Key lists one entry per placed copy, so the key list may
repeat exactly that name; everything else stays unique."""

from collections import Counter

from .. import CARD_ITEM_NAMES
from ..items import ITEM_GROUPS, PROGRESSIVE_LEVEL_KEY_NAME
from .bases import HP2TestBase


class _HintOrderChecks:
    """Shared assertions, mixed into a concrete mode-specific test case. Not a
    test case itself, so unittest never runs it with default options."""

    run_default_tests = False

    @staticmethod
    def _kinds() -> dict:
        return {
            "spell": set(ITEM_GROUPS["Spells"]),
            "key": set(ITEM_GROUPS["Blocker Keys"]) | {PROGRESSIVE_LEVEL_KEY_NAME},
            "card": set(CARD_ITEM_NAMES),
        }

    def _placed_by_kind(self) -> dict:
        kinds = self._kinds()
        placed = {kind: Counter() for kind in kinds}
        for location in self.multiworld.get_locations():
            item = location.item
            if item is None or item.player != self.player:
                continue
            for kind, names in kinds.items():
                if item.name in names:
                    placed[kind][item.name] += 1
                    break
        return placed

    def _sphere_of_name(self) -> dict:
        # A name placed as several copies (the progressive key) keeps its
        # earliest sphere, matching the first hint_order entry for that name.
        sphere_index = {}
        for index, sphere in enumerate(self.multiworld.get_spheres()):
            for location in sphere:
                sphere_index[location] = index
        spheres_by_name: dict = {}
        for location in self.multiworld.get_locations():
            item = location.item
            if item is not None and item.player == self.player:
                spheres_by_name.setdefault(item.name, []).append(sphere_index.get(location))
        return {
            name: min((s for s in spheres if s is not None), default=None)
            for name, spheres in spheres_by_name.items()
        }

    def test_hint_order_present_and_shaped(self) -> None:
        order = self.world.fill_slot_data()["hint_order"]
        self.assertEqual(set(order), {"spell", "key", "card"})
        for names in order.values():
            self.assertIsInstance(names, list)
            self.assertTrue(all(isinstance(name, str) for name in names))
            repeated = {name for name, n in Counter(names).items() if n > 1}
            self.assertTrue(repeated <= {PROGRESSIVE_LEVEL_KEY_NAME},
                            f"only the progressive key may repeat, got {sorted(repeated)}")

    def test_hint_order_categories_stay_pure(self) -> None:
        order = self.world.fill_slot_data()["hint_order"]
        kinds = self._kinds()
        for kind in kinds:
            self.assertTrue(set(order[kind]) <= kinds[kind])

    def test_hint_order_covers_this_slots_placed_items(self) -> None:
        order = self.world.fill_slot_data()["hint_order"]
        placed = self._placed_by_kind()
        for kind in placed:
            self.assertEqual(Counter(order[kind]), placed[kind])

    def test_hint_order_is_sphere_sorted(self) -> None:
        # Repeated names (progressive key copies) share one sphere lookup: the
        # per-name map keeps only one placement, so this checks the first-seen
        # ordering across distinct names is monotonic.
        order = self.world.fill_slot_data()["hint_order"]
        name_to_sphere = self._sphere_of_name()
        for names in order.values():
            spheres = [name_to_sphere[name] for name in dict.fromkeys(names)]
            spheres = [sphere for sphere in spheres if sphere is not None]
            self.assertEqual(spheres, sorted(spheres))


class TestHintOrderVanilla(_HintOrderChecks, HP2TestBase):
    options = {"game_mode": "vanilla"}


class TestHintOrderOpenCastle(_HintOrderChecks, HP2TestBase):
    options = {"game_mode": "open_castle"}
