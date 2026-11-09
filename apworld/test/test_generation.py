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


class TestOpenCastleEmptyStartRejected(HP2TestBase):
    """No starting spells, secrets and card shuffle off, containers on: every
    hub container wants a spell, and every vendor wants spells and keys or the
    Duelling Club, whose key is a found item while duelling is on. No location
    is open at the start, so generation must reject with a clear OptionError,
    not a FillError."""
    options = {"game_mode": "open_castle", **MINIMAL_CHECKS, "containersanity": True,
               "enable_duelling": True, "tradersanity": "price_random", "starting_spells": []}
    run_default_tests = False

    def setUp(self) -> None:
        pass

    def test_empty_start_rejected(self) -> None:
        with self.assertRaisesRegex(OptionError, "nothing is reachable at the start"):
            self.world_setup()


class TestOpenCastleEmptyStartInMultiworldGenerates(HP2TestBase):
    """The empty-start seed alongside a second slot with open locations: the
    guard accepts it because the other slot gives fill a place to start."""
    options = TestOpenCastleEmptyStartRejected.options
    run_default_tests = False

    def setUp(self) -> None:
        pass

    def test_another_slot_gives_the_start(self) -> None:
        from argparse import Namespace

        from BaseClasses import CollectionState, LocationProgressType, MultiWorld
        from test.general import gen_steps
        from worlds import AutoWorld

        multiworld = MultiWorld(2)
        multiworld.game = {1: self.game, 2: self.game}
        multiworld.player_name = {1: "Empty", 2: "Open"}
        multiworld.set_seed(1)
        world_type = AutoWorld.AutoWorldRegister.world_types[self.game]
        args = Namespace()
        for name, option in world_type.options_dataclass.type_hints.items():
            empty = self.options.get(name, option.default)
            setattr(args, name, {1: option.from_any(empty), 2: option.from_any(option.default)})
        multiworld.set_options(args)
        multiworld.state = CollectionState(multiworld)
        for step in gen_steps:
            AutoWorld.call_all(multiworld, step)
        state = CollectionState(multiworld)
        state.sweep_for_advancements()

        def open_at_start(player: int) -> int:
            return sum(1 for loc in multiworld.get_locations(player)
                       if loc.item is None and loc.progress_type != LocationProgressType.EXCLUDED
                       and loc.can_reach(state))

        self.assertEqual(open_at_start(1), 0)
        self.assertGreater(open_at_start(2), 0)


class TestOpenCastleOneSpellStartGenerates(HP2TestBase):
    """The same seed with Alohomora to start has open hub containers, so the
    empty-start guard lets it through. A start this small passes the guard but
    can still fail fill on an unlucky seed."""
    options = {"game_mode": "open_castle", **MINIMAL_CHECKS, "containersanity": True,
               "enable_duelling": True, "tradersanity": "price_random", "starting_spells": ["Alohomora"]}


class TestOpenCastleSecretsOnlyGenerates(HP2TestBase):
    """Secrets live in pre-key hub regions, so enabling them alone gives the
    level keys reachable homes and a low-check open-castle seed still generates
    and fills. Guards against the overfill rejection being too aggressive.
    (Behind-key categories like challenge stars or duels do NOT suffice on their
    own: their locations sit inside locked levels, so they give the keys no
    pre-key home.)"""
    options = {"game_mode": "open_castle", **MINIMAL_CHECKS, "enable_secrets": True}
