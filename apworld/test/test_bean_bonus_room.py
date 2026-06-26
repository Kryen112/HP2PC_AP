"""The bean bonus room is a containersanity region in both modes. Open castle
reaches it freely (entry `always`); vanilla reaches it by completing the
Rictusempra challenge (entry lumos & flipendo & rictusempra), opens its
containers with Alohomora, and the room is a one-shot timed visit so its 7
containers are missable. They therefore ride allow_missable_progression like any
other one-way-level container."""

from BaseClasses import CollectionState, LocationProgressType

from .bases import HP2TestBase

EXCLUDED = LocationProgressType.EXCLUDED

BEAN_ROOM = (
    "Bean Bonus Room - Chest 1",
    "Bean Bonus Room - Chest 2",
    "Bean Bonus Room - Chest 3",
    "Bean Bonus Room - Chest 4",
    "Bean Bonus Room - Chest 5",
    "Bean Bonus Room - Chest 6",
    "Bean Bonus Room - Gargoyle",
)


class TestBeanRoomPresentVanilla(HP2TestBase):
    """With containersanity on, the 7 bean containers are real vanilla checks."""
    options = {"game_mode": "vanilla", "containersanity": True}
    run_default_tests = False

    def test_present(self) -> None:
        for name in BEAN_ROOM:
            try:
                self.world.get_location(name)
            except KeyError:
                self.fail(f"{name} should exist in vanilla with containersanity on.")


class TestBeanRoomAbsentWithoutContainersanity(HP2TestBase):
    """No containersanity -> the bean containers are not checks at all."""
    options = {"game_mode": "vanilla", "containersanity": False}
    run_default_tests = False

    def test_absent(self) -> None:
        for name in BEAN_ROOM:
            self.assertRaises(KeyError, self.world.get_location, name)


class TestBeanRoomPresentOpenCastle(HP2TestBase):
    """Dropping BeanBonusRoom from the open-castle-only set must not strip it
    from open castle, where it has always been a check."""
    options = {"game_mode": "open_castle", "containersanity": True}
    run_default_tests = False

    def test_present(self) -> None:
        for name in BEAN_ROOM:
            try:
                self.world.get_location(name)
            except KeyError:
                self.fail(f"{name} should still exist in open castle.")


class TestBeanRoomVanillaReachability(HP2TestBase):
    # Spells emptied so every spell sits in the pool and collect_all_but can
    # withhold one at a time.
    options = {"game_mode": "vanilla", "containersanity": True, "starting_spells": []}
    run_default_tests = False

    def test_blocked_without_any_required_spell(self) -> None:
        # Entry = lumos & flipendo & rictusempra; container = alohomora. Lumos
        # and Flipendo are force-precollected in vanilla (generate_early), so
        # they cannot be withheld here; Rictusempra (entry) and Alohomora
        # (container) are the two that actually gate the check.
        for missing in ("Rictusempra", "Alohomora"):
            state = CollectionState(self.multiworld)
            self.collect_all_but([missing], state)
            self.assertFalse(
                state.can_reach("Bean Bonus Room - Chest 1", "Location", self.player),
                f"bean chest should be blocked without {missing}")

    def test_reachable_with_all_four(self) -> None:
        state = CollectionState(self.multiworld)
        self.collect_all_but([], state)
        self.assertTrue(
            state.can_reach("Bean Bonus Room - Chest 1", "Location", self.player),
            "bean chest should be reachable once the full spell set is held")


class TestBeanRoomExcludedByDefault(HP2TestBase):
    options = {"game_mode": "vanilla", "containersanity": True, "allow_missable_progression": False}
    run_default_tests = False

    def test_excluded(self) -> None:
        for name in BEAN_ROOM:
            self.assertEqual(self.world.get_location(name).progress_type, EXCLUDED,
                             f"{name} must be EXCLUDED without allow_missable_progression")


class TestBeanRoomDefaultStartersStillExcluded(HP2TestBase):
    # allow_missable_progression on, but the default starters (Flipendo/Lumos/
    # Alohomora) lack Rictusempra, which the bean room depends on, so it stays
    # EXCLUDED.
    options = {"game_mode": "vanilla", "containersanity": True, "allow_missable_progression": True}
    run_default_tests = False

    def test_still_excluded_without_rictusempra(self) -> None:
        self.assertEqual(self.world.get_location("Bean Bonus Room - Chest 1").progress_type, EXCLUDED,
                         "missing Rictusempra dep -> still EXCLUDED")


class TestBeanRoomEligibleWhenDepsPrecollected(HP2TestBase):
    # Every dep (Alohomora, Flipendo, Lumos, Rictusempra) precollected as a
    # starting spell, so the room may now hold progression.
    options = {
        "game_mode": "vanilla",
        "containersanity": True,
        "allow_missable_progression": True,
        "starting_spells": ["Alohomora", "Flipendo", "Lumos", "Rictusempra"],
    }
    run_default_tests = False

    def test_eligible(self) -> None:
        for name in BEAN_ROOM:
            self.assertNotEqual(self.world.get_location(name).progress_type, EXCLUDED,
                                f"{name}: every dep precollected -> eligible")
