"""Edge and boundary option combinations. Each must still generate a solvable
seed: the goal-clause fallbacks, the contradictory goal-vs-disabled-category
case the world clamps, the starting-spell extremes, and traps disabled."""

from .bases import HP2TestBase


class TestOpenCastleGoalAllZero(HP2TestBase):
    """Every goal clause zero/off falls back to an all-spells gate."""
    options = {
        "game_mode": "open_castle",
        "open_castle_goal_cards": 0,
        "open_castle_goal_spells": 0,
        "open_castle_goal_levels": 0,
        "open_castle_goal_duels": False,
        "open_castle_goal_quidditch": False,
    }


class TestOpenCastleGoalDuelsOnly(HP2TestBase):
    options = {
        "game_mode": "open_castle",
        "open_castle_goal_cards": 0,
        "open_castle_goal_spells": 0,
        "open_castle_goal_levels": 0,
        "open_castle_goal_duels": True,
        "enable_duelling": True,
    }


class TestOpenCastleGoalQuidditchOnly(HP2TestBase):
    options = {
        "game_mode": "open_castle",
        "open_castle_goal_cards": 0,
        "open_castle_goal_spells": 0,
        "open_castle_goal_levels": 0,
        "open_castle_goal_quidditch": True,
        "enable_quidditch_matches": True,
    }


class TestOpenCastleContradictoryCardGoal(HP2TestBase):
    """A card goal while cards are disabled: the world must clamp the goal to
    what is reachable rather than emit an unwinnable seed."""
    options = {
        "game_mode": "open_castle",
        "enable_wizard_cards": False,
        "open_castle_goal_cards": 50,
    }


class TestNoStartingSpells(HP2TestBase):
    """Vanilla auto-adds Lumos + Flipendo when the starting set omits them."""
    options = {"game_mode": "vanilla", "starting_spells": []}


class TestAllStartingSpells(HP2TestBase):
    options = {
        "game_mode": "vanilla",
        "starting_spells": ["Alohomora", "Flipendo", "Lumos", "Rictusempra",
                            "Skurge", "Diffindo", "Spongify"],
    }


class TestTrapsDisabledFillHigh(HP2TestBase):
    """Empty trap set with a high trap-fill percent yields filler, not a crash."""
    options = {"game_mode": "vanilla", "traps": [], "trap_fill_percent": 50}
