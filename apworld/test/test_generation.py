"""Generation matrix: each class is one option combination, run through
WorldTestBase's default battery (test_fill, all/empty-state reachability,
completion reachable). Covers both game modes, the all-checks-on and minimal
seeds, the runtime link/randomizer toggles, and a trap-heavy fill."""

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
