from .bases import HP2TestBase

POST_ENDING_CHESTS = ("Entry Hall - Chest 7", "Entry Hall - Chest 8")


class TestPostEndingChestsOpenCastle(HP2TestBase):
    """Open castle strands these two chests past the ending cutscene, so they
    must not be created as checks at all."""
    options = {
        "game_mode": "open_castle",
        "containersanity": True,
    }
    run_default_tests = False

    def test_post_ending_chests_absent(self) -> None:
        for name in POST_ENDING_CHESTS:
            self.assertRaises(KeyError, self.world.get_location, name)

    def test_exclusion_is_scoped(self) -> None:
        # Only the two stranded chests drop out; the rest of the Entry Hall
        # containers stay reachable in open castle.
        try:
            self.world.get_location("Entry Hall - Chest 1")
        except KeyError:
            self.fail("Entry Hall - Chest 1 should exist in open castle.")


class TestPostEndingChestsVanilla(HP2TestBase):
    """Vanilla traverses the east wing normally, so both chests stay checks."""
    options = {
        "game_mode": "vanilla",
        "containersanity": True,
    }
    run_default_tests = False

    def test_post_ending_chests_present(self) -> None:
        for name in POST_ENDING_CHESTS:
            try:
                self.world.get_location(name)
            except KeyError:
                self.fail(f"{name} should exist in vanilla.")
