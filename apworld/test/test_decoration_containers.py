"""Containersanity decoration props: inert statues / skeleton / plant dragons the
mod gives a Flipendo break. Pins their presence (gated on containersanity), the
Flipendo (plus per-level traversal) access rules, and the one-way Whomping Willow
statue being missable like the level's other one-way containers. Full-fill solvability
with these present is covered by test_generation's all-checks-on classes."""

from BaseClasses import CollectionState, LocationProgressType

from .bases import HP2TestBase

EXCLUDED = LocationProgressType.EXCLUDED

DECORATION_LOCATIONS = (
    "Whomping Willow - Dragon Statue",
    "Skurge Challenge - Witch Statue",
    "Entry Hall - Witch Statue",
    "Grand Staircase - Gregory the Smarmy Statue",
    "Grand Staircase - Dragon Skeleton",
    "Castle Exterior - Dragon Statue",
    "Castle Exterior - Plant Dragon 1",
    "Castle Exterior - Plant Dragon 2",
    "Grand Staircase - Toilet",
)

# Statues at easy, freely-reachable spots: Flipendo is their only gate. The Castle
# Exterior plant dragons also need only Flipendo in open castle but are tested
# separately (vanilla gates them behind the level traversal chain).
HUB_STATUES = (
    "Entry Hall - Witch Statue",
    "Grand Staircase - Gregory the Smarmy Statue",
    "Grand Staircase - Dragon Skeleton",
    "Castle Exterior - Dragon Statue",
)


class TestDecorationContainersPresent(HP2TestBase):
    options = {"game_mode": "open_castle", "containersanity": True}
    run_default_tests = False

    def test_all_present(self) -> None:
        for name in DECORATION_LOCATIONS:
            self.world.get_location(name)  # raises KeyError if missing


class TestDecorationContainersAbsentWithoutOption(HP2TestBase):
    options = {"game_mode": "open_castle", "containersanity": False}
    run_default_tests = False

    def test_absent(self) -> None:
        for name in ("Entry Hall - Witch Statue", "Castle Exterior - Dragon Statue"):
            self.assertRaises(KeyError, self.world.get_location, name)


class TestHubStatuesNeedFlipendo(HP2TestBase):
    options = {"game_mode": "open_castle", "containersanity": True, "starting_spells": []}
    run_default_tests = False

    def test_flipendo_gate(self) -> None:
        for name in HUB_STATUES:
            self.assertAccessDependency([name], [["Flipendo"]], only_check_listed=True)


class TestSkurgeWitchNeedsSkurgeAndFlipendo(HP2TestBase):
    # The Skurge challenge witch needs both the Skurge spell (to be in the challenge)
    # and Flipendo (to break it); removing either strands it.
    options = {"game_mode": "open_castle", "containersanity": True, "starting_spells": []}
    run_default_tests = False

    def test_both_required(self) -> None:
        loc = "Skurge Challenge - Witch Statue"
        full = CollectionState(self.multiworld)
        self.collect_all_but([], full)
        self.assertTrue(full.can_reach(loc, "Location", self.player),
                        "reachable with everything collected")
        for missing in ("Skurge", "Flipendo"):
            state = CollectionState(self.multiworld)
            self.collect_all_but([missing], state)
            self.assertFalse(state.can_reach(loc, "Location", self.player),
                             f"{loc} reachable without {missing}")


class TestPlantDragonsNeedFlipendo(HP2TestBase):
    # Open castle: both Castle Exterior plant dragons just need Flipendo (the
    # Castle Exterior region is unrestricted there), like the hub statues.
    # Vanilla layers the level's traversal chain on top (it crosses the open
    # castle rule via the Running escape, so it is tested by the chain tests).
    options = {"game_mode": "open_castle", "containersanity": True,
               "allow_running_logic": False, "starting_spells": []}
    run_default_tests = False

    def test_both_plant_dragons_need_only_flipendo(self) -> None:
        for name in ("Castle Exterior - Plant Dragon 1", "Castle Exterior - Plant Dragon 2"):
            self.assertAccessDependency([name], [["Flipendo"]], only_check_listed=True)


class TestSkeletonVanillaNeedsRictusempra(HP2TestBase):
    # Grand Staircase Dragon Skeleton: vanilla adds Rictusempra on top of Flipendo; open
    # castle needs only Flipendo (the Flipendo gate is covered by TestHubStatuesNeedFlipendo).
    options = {"game_mode": "vanilla", "containersanity": True, "starting_spells": []}
    run_default_tests = False

    def test_needs_rictusempra(self) -> None:
        loc = "Grand Staircase - Dragon Skeleton"
        without = CollectionState(self.multiworld)
        self.collect_all_but(["Rictusempra"], without)
        self.assertFalse(without.can_reach(loc, "Location", self.player),
                         "vanilla skeleton must require Rictusempra")
        full = CollectionState(self.multiworld)
        self.collect_all_but([], full)
        self.assertTrue(full.can_reach(loc, "Location", self.player),
                        "reachable with everything collected")


class TestToiletNeedsChamberKeyAndFlipendo(HP2TestBase):
    # Myrtle's-bathroom toilet sits behind the Chamber of Secrets entrance: open castle
    # gates it on the Chamber of Secrets Key plus Flipendo to break it.
    options = {"game_mode": "open_castle", "containersanity": True, "starting_spells": []}
    run_default_tests = False

    def test_key_and_flipendo_required(self) -> None:
        loc = "Grand Staircase - Toilet"
        full = CollectionState(self.multiworld)
        self.collect_all_but([], full)
        self.assertTrue(full.can_reach(loc, "Location", self.player),
                        "reachable with everything collected")
        for missing in ("Chamber of Secrets Key", "Flipendo"):
            state = CollectionState(self.multiworld)
            self.collect_all_but([missing], state)
            self.assertFalse(state.can_reach(loc, "Location", self.player),
                             f"{loc} reachable without {missing}")


class TestToiletVanillaNeedsSpells(HP2TestBase):
    # Vanilla reaches the bathroom via the story flow: Rictusempra and Skurge gate it.
    # Flipendo also breaks the toilet but is precollected in vanilla, so removing it from
    # the pool cannot strand the check; removing either learned spell does.
    options = {"game_mode": "vanilla", "containersanity": True, "starting_spells": []}
    run_default_tests = False

    def test_spells_required(self) -> None:
        loc = "Grand Staircase - Toilet"
        full = CollectionState(self.multiworld)
        self.collect_all_but([], full)
        self.assertTrue(full.can_reach(loc, "Location", self.player),
                        "reachable with everything collected")
        for missing in ("Rictusempra", "Skurge"):
            state = CollectionState(self.multiworld)
            self.collect_all_but([missing], state)
            self.assertFalse(state.can_reach(loc, "Location", self.player),
                             f"vanilla {loc} reachable without {missing}")


class TestWillowDragonStatueMissable(HP2TestBase):
    # Whomping Willow is one-way, so its dragon statue is missable: excluded from
    # progression unless allow_missable_progression is on.
    options = {"game_mode": "vanilla", "containersanity": True,
               "allow_missable_progression": False}
    run_default_tests = False

    def test_excluded_by_default(self) -> None:
        self.assertEqual(self.world.get_location("Whomping Willow - Dragon Statue").progress_type,
                         EXCLUDED, "one-way Willow statue must be EXCLUDED by default")
