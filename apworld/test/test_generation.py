"""Generation matrix: each class is one option combination, run through
WorldTestBase's default battery (test_fill, all/empty-state reachability,
completion reachable). Covers both game modes, the all-checks-on and minimal
seeds, the runtime link/randomizer toggles, and a trap-heavy fill."""

from Options import OptionError

from .bases import HP2TestBase

# Every per-category check turned on (the maximal seed): cards, secrets, stars,
# duels, quidditch, spell-challenge times, vendor upgrades, containers, and a
# priced Tradersanity.
ALL_CHECKS_ON = {
    "enable_wizard_cards": True,
    "enable_secrets": True,
    "enable_challenge_stars": True,
    "enable_duelling": True,
    "enable_quidditch_matches": True,
    "enable_spell_challenge_times": True,
    "enable_quidditch_upgrades": True,
    "containersanity": True,
    "tradersanity": "price_random",
}

# Every togglable check off: the seed collapses to the always-present spells +
# classrooms (per the options docstring).
MINIMAL_CHECKS = {
    "enable_wizard_cards": False,
    "enable_secrets": False,
    "enable_challenge_stars": False,
    "enable_duelling": False,
    "enable_quidditch_matches": False,
    "enable_spell_challenge_times": False,
    "enable_quidditch_upgrades": False,
    "containersanity": False,
    "tradersanity": "off",
}


class TestVanillaDefault(HP2TestBase):
    options = {"game_mode": "vanilla"}


class TestOpenCastleDefault(HP2TestBase):
    options = {"game_mode": "open_castle"}


class TestVanillaAllChecks(HP2TestBase):
    options = {"game_mode": "vanilla", **ALL_CHECKS_ON}


class TestOpenCastleAllChecks(HP2TestBase):
    options = {"game_mode": "open_castle", **ALL_CHECKS_ON}


class TestVanillaMinimal(HP2TestBase):
    options = {"game_mode": "vanilla", **MINIMAL_CHECKS}


class TestVanillaLinksAndRandomizers(HP2TestBase):
    """Runtime-only channels (ring/trap/death link) and the asset randomizers
    must not perturb fill or solvability."""
    options = {
        "game_mode": "vanilla",
        "ring_link": True,
        "trap_link": True,
        "death_link": True,
        "allow_running_logic": True,
        "allow_glitched_logic": True,
        "allow_missable_progression": True,
        "music_randomizer": True,
        "sound_randomizer": "on",
        "dialogue_randomizer": "all_actors",
    }


class TestVanillaTrapHeavy(HP2TestBase):
    """Max trap fill still leaves a solvable seed."""
    options = {"game_mode": "vanilla", "trap_fill_percent": 50}


class TestOpenCastleMinimalRejected(HP2TestBase):
    """All check categories off in open castle: no pre-key home for the level
    keys. Generation must reject with a clear OptionError, not a FillError."""
    options = {"game_mode": "open_castle", **MINIMAL_CHECKS}
    run_default_tests = False

    def setUp(self) -> None:
        pass  # world_setup is expected to raise; drive it inside the test

    def test_minimal_open_castle_rejected(self) -> None:
        with self.assertRaises(OptionError):
            self.world_setup()


class TestOpenCastleBehindKeyOnlyRejected(HP2TestBase):
    """Plenty of checks, but all behind level keys (stars + duels + quidditch
    matches) with no seeder category. The keys have no pre-key home, so the
    seeding guard must reject even though the location count is ample."""
    options = {"game_mode": "open_castle", **MINIMAL_CHECKS,
               "enable_challenge_stars": True, "enable_duelling": True,
               "enable_quidditch_matches": True}
    run_default_tests = False

    def setUp(self) -> None:
        pass

    def test_behind_key_only_rejected(self) -> None:
        with self.assertRaises(OptionError):
            self.world_setup()


class TestOpenCastleCardsShuffledOnlyRejected(HP2TestBase):
    """Shuffled cards seed the keys (a valid seeder), but with every other
    category off the 101 cards + 14 keys + spells overflow the 114 locations.
    The count guard must reject this even though the seeding guard passes."""
    options = {"game_mode": "open_castle", **MINIMAL_CHECKS, "enable_wizard_cards": True}
    run_default_tests = False

    def setUp(self) -> None:
        pass

    def test_cards_shuffled_only_rejected(self) -> None:
        with self.assertRaises(OptionError):
            self.world_setup()


class TestOpenCastleSecretsOnlyGenerates(HP2TestBase):
    """Secrets live in pre-key hub regions, so enabling them alone gives the
    level keys reachable homes and a low-check open-castle seed still generates
    and fills. Guards against the overfill rejection being too aggressive.
    (Behind-key categories like challenge stars or duels do NOT suffice on their
    own: their locations sit inside locked levels, so they give the keys no
    pre-key home.)"""
    options = {"game_mode": "open_castle", **MINIMAL_CHECKS, "enable_secrets": True}
