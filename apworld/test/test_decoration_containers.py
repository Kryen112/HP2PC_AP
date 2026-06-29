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
)

# Statues at easy, freely-reachable spots: Flipendo is their only gate. The Castle
# Exterior plant dragons sit at harder reaches (Secrets 6 / 7) and are tested separately.
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


class TestPlantDragonsMatchCastleSecrets(HP2TestBase):
    # The Castle Exterior plant dragons mirror that level's Secrets 6 / 7. Open castle:
    # Plant Dragon 2 needs Diffindo (Secret 7); Plant Dragon 1 is reachable without
    # Flipendo via Spongify (Secret 6's flipendo | spongify | running).
    options = {"game_mode": "open_castle", "containersanity": True,
               "allow_running_logic": False, "starting_spells": []}
    run_default_tests = False

    def test_plant_dragon_2_needs_diffindo(self) -> None:
        self.assertAccessDependency(["Castle Exterior - Plant Dragon 2"],
                                    [["Diffindo"]], only_check_listed=True)

    def test_plant_dragon_1_reachable_via_spongify_without_flipendo(self) -> None:
        state = CollectionState(self.multiworld)
        self.collect_all_but(["Flipendo"], state)
        self.assertTrue(
            state.can_reach("Castle Exterior - Plant Dragon 1", "Location", self.player),
            "Plant Dragon 1 should be reachable via Spongify even without Flipendo")


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


class TestWillowDragonStatueMissable(HP2TestBase):
    # Whomping Willow is one-way, so its dragon statue is missable: excluded from
    # progression unless allow_missable_progression is on.
    options = {"game_mode": "vanilla", "containersanity": True,
               "allow_missable_progression": False}
    run_default_tests = False

    def test_excluded_by_default(self) -> None:
        self.assertEqual(self.world.get_location("Whomping Willow - Dragon Statue").progress_type,
                         EXCLUDED, "one-way Willow statue must be EXCLUDED by default")
