"""Missable locations live in one-way vanilla levels: they may only hold
progression when allow_missable_progression is on AND every dependency item is
precollected (so the player is guaranteed to hold them while passing through).
Otherwise the location is marked EXCLUDED so fill keeps progression out of it.
"Precollected" here is the world's starter set (starting_spells + the keys not
gating a bookcase this seed), per HP2World._starter_names.

Secrets are used as the sample missables since they exist with the default
enable_secrets (chests would need containersanity)."""

from BaseClasses import LocationProgressType

from .bases import HP2TestBase

EXCLUDED = LocationProgressType.EXCLUDED

SAMPLE_MISSABLE = (
    "Whomping Willow - Secret 1",  # deps: Alohomora, Lumos
    "Bicorn Level - Secret 1",     # deps: Alohomora, Bicorn Level Key, Flipendo, Lumos, Rictusempra, Skurge
    "Bicorn Level - Secret 2",     # same deps as Secret 1
)


class TestMissableExcludedByDefault(HP2TestBase):
    options = {"game_mode": "vanilla", "allow_missable_progression": False}
    run_default_tests = False

    def test_missables_are_excluded(self) -> None:
        for name in SAMPLE_MISSABLE:
            self.assertEqual(self.world.get_location(name).progress_type, EXCLUDED,
                             f"{name} must be EXCLUDED when allow_missable_progression is off")


class TestMissableEligibilityFollowsPrecollect(HP2TestBase):
    # allow_missable_progression on, with the default starters Flipendo/Lumos/Alohomora.
    options = {"game_mode": "vanilla", "allow_missable_progression": True}
    run_default_tests = False

    def test_precollected_dep_location_eligible(self) -> None:
        # Depends only on Alohomora + Lumos (both default starters), so it may
        # now hold progression.
        self.assertNotEqual(self.world.get_location("Whomping Willow - Secret 1").progress_type,
                            EXCLUDED, "all deps precollected -> eligible")

    def test_unsatisfied_dep_location_still_excluded(self) -> None:
        # Needs the (gated) Bicorn key + Rictusempra + Skurge, none precollected,
        # so it stays EXCLUDED even with the option on.
        self.assertEqual(self.world.get_location("Bicorn Level - Secret 2").progress_type, EXCLUDED,
                         "deps not fully precollected -> still EXCLUDED")


class TestMissableEligibleWhenAllDepsPrecollected(HP2TestBase):
    # vanilla_gate_levels off precollects all 14 keys (including the Bicorn key);
    # adding Rictusempra + Skurge to the starting spells satisfies every dep of
    # the deep Bicorn secret, so it becomes eligible.
    options = {
        "game_mode": "vanilla",
        "allow_missable_progression": True,
        "vanilla_gate_levels": False,
        "starting_spells": ["Alohomora", "Flipendo", "Lumos", "Rictusempra", "Skurge"],
    }
    run_default_tests = False

    def test_deep_missable_eligible_when_keys_precollected(self) -> None:
        self.assertNotEqual(self.world.get_location("Bicorn Level - Secret 2").progress_type,
                            EXCLUDED, "every dep precollected -> eligible")
