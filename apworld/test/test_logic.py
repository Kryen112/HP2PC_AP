"""Targeted access-rule tests that pin specific logic/data behaviors so a future
logic edit can't silently break them: bookcase/level blocker keys, per-category
location gating, and the Running-logic shortcut."""

from .bases import HP2TestBase
from ..access import _BRONZE_CARD_NAMES, _SILVER_CARD_NAMES
from ..rules import CHAMBER_FALL_BRONZE_COUNT


# Each of the 14 level/challenge regions is gated standalone by its own key in
# open castle (no cumulative chain). One representative location per region.
KEY_TO_LOCATION = {
    "Bicorn Level Key": "Bicorn Level - Card Agrippa",
    "Boomslang Level Key": "Boomslang Level - Card Toke",
    "Goyle Level Key": "Goyle Level - Card Bloxam",
    "Slytherin Common Room Key": "Slytherin Common Room - Card Pilliwickle",
    "Forbidden Forest Key": "Forbidden Forest - Card Fancourt",
    "Whomping Willow Key": "Whomping Willow - Card Starkey",
    "Rictusempra Challenge Key": "Rictusempra Challenge - Card Barbary",
    "Skurge Challenge Key": "Skurge Challenge - Card Belby",
    "Diffindo Challenge Key": "Diffindo Challenge - Card Ketteridge",
    "Spongify Challenge Key": "Spongify Challenge - Card Merlin",
    "Gryffindor Challenge Key": "Gryffindor Challenge - Secret 1",
    "Duelling Key": "Duelling Club - Duel Rank 1",
    "Quidditch Key": "Quidditch - Match 1 (Hufflepuff)",
    "Chamber of Secrets Key": "Chamber of Secrets - Card Elphick",
}


# starting_spells emptied so every spell sits in the pool (only the key under
# test is missing); Running off so the Quidditch key has no shortcut; duels and
# matches enabled so those regions have locations.
class TestOpenCastleLevelKeys(HP2TestBase):
    options = {
        "game_mode": "open_castle",
        "starting_spells": [],
        "allow_running_logic": False,
        "enable_duelling": True,
        "enable_quidditch_matches": True,
    }
    run_default_tests = False

    def test_each_region_gated_by_its_key(self) -> None:
        for key, loc in KEY_TO_LOCATION.items():
            self.assertAccessDependency([loc], [[key]], only_check_listed=True)


# Forbidden Forest is enterable from the start when Running logic is on: the
# open-castle region rule is forbidden_forest_key OR Running. With Running off
# the key stays the only gate (covered by TestOpenCastleLevelKeys above); with
# Running on the precollected flag opens the region without the key.
class TestForbiddenForestRunningShortcut(HP2TestBase):
    options = {"game_mode": "open_castle", "allow_running_logic": True, "starting_spells": []}
    run_default_tests = False

    def test_region_reachable_without_key_via_running(self) -> None:
        state = self.state_all_but(["Forbidden Forest Key"])
        self.assertTrue(
            state.can_reach("ForbiddenForest", "Region", self.player),
            "Running should open the Forbidden Forest region without the key")


class TestForbiddenForestKeyGatedWithoutRunning(HP2TestBase):
    options = {"game_mode": "open_castle", "allow_running_logic": False, "starting_spells": []}
    run_default_tests = False

    def test_region_needs_key_without_running(self) -> None:
        state = self.state_all_but(["Forbidden Forest Key"])
        self.assertFalse(
            state.can_reach("ForbiddenForest", "Region", self.player),
            "without Running the Forbidden Forest region still needs its key")


# Open-castle Goyle Level - Chest 3 sits in a dark area, so its rule adds Lumos on
# top of the lit-area spell set, matching sibling Chests 5, 8, and 11. Pin it so a
# future edit cannot silently drop the Lumos gate. containersanity on so the chest
# location exists; starting_spells empty and Running off so Lumos is the isolated
# pool-gated differentiator.
class TestGoyleChest3NeedsLumos(HP2TestBase):
    options = {
        "game_mode": "open_castle",
        "starting_spells": [],
        "allow_running_logic": False,
        "containersanity": True,
    }
    run_default_tests = False

    def test_chest_3_needs_lumos(self) -> None:
        self.assertAccessDependency(["Goyle Level - Chest 3"],
                                    [["Lumos"]], only_check_listed=True)


# Running-logic shortcut: Castle Exterior - Card Pokeby is gated behind a spell
# chain OR Running. With Running off it genuinely needs the spells, so removing
# Rictusempra strands it.
class TestRunningOffNeedsSpellChain(HP2TestBase):
    options = {"game_mode": "vanilla", "allow_running_logic": False, "starting_spells": []}
    run_default_tests = False

    def test_pokeby_needs_rictusempra_without_running(self) -> None:
        self.assertAccessDependency(["Castle Exterior - Card Pokeby"],
                                    [["Rictusempra"]], only_check_listed=True)


# Per-category toggles gate their matching locations: off -> the location is not
# even created; on -> it exists.
class TestQuidditchUpgradesGateEquipment(HP2TestBase):
    options = {"game_mode": "vanilla", "enable_quidditch_upgrades": True}
    run_default_tests = False

    def test_equipment_locations_present(self) -> None:
        self.assert_location_exists("Castle Exterior - Nimbus 2001")
        self.assert_location_exists("Castle Exterior - Quidditch Armour")


class TestQuidditchUpgradesOffNoEquipment(HP2TestBase):
    options = {"game_mode": "vanilla", "enable_quidditch_upgrades": False}
    run_default_tests = False

    def test_equipment_locations_absent(self) -> None:
        self.assertRaises(KeyError, self.world.get_location, "Castle Exterior - Nimbus 2001")
        self.assertRaises(KeyError, self.world.get_location, "Castle Exterior - Quidditch Armour")


class TestDuellingTogglePresence(HP2TestBase):
    options = {"game_mode": "vanilla", "enable_duelling": True}
    run_default_tests = False

    def test_duel_locations_present(self) -> None:
        self.assert_location_exists("Duelling Club - Duel Rank 1")


class TestDuellingOffAbsent(HP2TestBase):
    options = {"game_mode": "vanilla", "enable_duelling": False}
    run_default_tests = False

    def test_duel_locations_absent(self) -> None:
        self.assertRaises(KeyError, self.world.get_location, "Duelling Club - Duel Rank 1")


class TestQuidditchMatchesTogglePresence(HP2TestBase):
    options = {"game_mode": "vanilla", "enable_quidditch_matches": True}
    run_default_tests = False

    def test_match_locations_present(self) -> None:
        self.assert_location_exists("Quidditch - Match 1 (Hufflepuff)")


class TestQuidditchMatchesOffAbsent(HP2TestBase):
    options = {"game_mode": "vanilla", "enable_quidditch_matches": False}
    run_default_tests = False

    def test_match_locations_absent(self) -> None:
        self.assertRaises(KeyError, self.world.get_location, "Quidditch - Match 1 (Hufflepuff)")


# Running on: the spell chain becomes optional, so Pokeby is reachable without
# Rictusempra/Skurge/the Bicorn key (Running is precollected, Alohomora is in pool).
class TestRunningOnSkipsSpellChain(HP2TestBase):
    options = {"game_mode": "vanilla", "allow_running_logic": True, "starting_spells": []}
    run_default_tests = False

    def test_pokeby_reachable_via_running(self) -> None:
        state = self.state_all_but(["Rictusempra", "Skurge", "Bicorn Level Key"])
        self.assertTrue(
            state.can_reach("Castle Exterior - Card Pokeby", "Location", self.player),
            "Running should bypass the Rictusempra/Skurge/Bicorn-key chain")


# Vanilla physically needs Lumos + Flipendo (Whomping Willow), so they are forced
# into the starting set even when omitted; open castle honors the set as-is.
class TestVanillaForcesLumosFlipendo(HP2TestBase):
    options = {"game_mode": "vanilla", "starting_spells": []}
    run_default_tests = False

    def test_lumos_flipendo_auto_added(self) -> None:
        spells = set(self.world.options.starting_spells.value)
        self.assertIn("Lumos", spells)
        self.assertIn("Flipendo", spells)


class TestOpenCastleHonorsEmptyStartingSpells(HP2TestBase):
    options = {"game_mode": "open_castle", "starting_spells": []}
    run_default_tests = False

    def test_no_spells_forced(self) -> None:
        self.assertEqual(set(self.world.options.starting_spells.value), set())


# Same hub card gates differently per mode: open castle requires Alohomora, which
# the vanilla rule (region-gated on the forced Lumos+Flipendo) does not add.
class TestOpenCastleHubGate(HP2TestBase):
    options = {"game_mode": "open_castle", "starting_spells": []}
    run_default_tests = False

    def test_entry_hall_card_needs_alohomora(self) -> None:
        self.assertAccessDependency(["Entry Hall - Card Alderton"],
                                    [["Alohomora"]], only_check_listed=True)


# Open-castle Chamber of Secrets: the first fall in is skippable with 20 bronze
# cards (two extra health rows) instead of Spongify, but only for the six spots
# behind that first fall. Deeper Spongify gates stay real. starting_spells empty
# so Spongify sits in the pool rather than being precollected; containersanity on
# so the cauldron/chest/jar locations exist.
class TestChamberFirstFallBronzeSkip(HP2TestBase):
    options = {
        "game_mode": "open_castle",
        "starting_spells": [],
        "allow_running_logic": False,
        "containersanity": True,
    }
    run_default_tests = False

    # Region entry (Chamber of Secrets Key + Alohomora) plus the per-location
    # spell. Cauldron 1 also needs Flipendo; the deeper Cauldron 3 adds Diffindo
    # and Skurge on top of its non-skippable Spongify. The bronze counts come
    # from the rule's own threshold so a balance change keeps the test honest.
    def test_threshold_bronze_skips_first_fall(self) -> None:
        state = self.state_with(
            ["Chamber of Secrets Key", "Alohomora", "Flipendo"]
            + _BRONZE_CARD_NAMES[:CHAMBER_FALL_BRONZE_COUNT])
        self.assertTrue(
            state.can_reach("Chamber of Secrets - Cauldron 1", "Location", self.player),
            "the bronze threshold should let Harry tank the first fall without Spongify")

    def test_one_under_threshold_is_not_enough(self) -> None:
        state = self.state_with(
            ["Chamber of Secrets Key", "Alohomora", "Flipendo"]
            + _BRONZE_CARD_NAMES[:CHAMBER_FALL_BRONZE_COUNT - 1])
        self.assertFalse(
            state.can_reach("Chamber of Secrets - Cauldron 1", "Location", self.player),
            "one bronze below the threshold is not enough to survive the fall")

    def test_spongify_still_reaches_first_fall_without_bronze(self) -> None:
        state = self.state_with(
            ["Chamber of Secrets Key", "Alohomora", "Flipendo", "Spongify"])
        self.assertTrue(
            state.can_reach("Chamber of Secrets - Cauldron 1", "Location", self.player),
            "Spongify remains a valid path for the first fall")

    def test_bronze_does_not_skip_a_deeper_spongify_gate(self) -> None:
        state = self.state_with(
            ["Chamber of Secrets Key", "Alohomora", "Flipendo", "Diffindo", "Skurge"]
            + _BRONZE_CARD_NAMES[:CHAMBER_FALL_BRONZE_COUNT])
        self.assertFalse(
            state.can_reach("Chamber of Secrets - Cauldron 3", "Location", self.player),
            "the deeper Cauldron 3 Spongify gate is not bronze-skippable")


# The same first-fall rule lives in the vanilla table for consistency, but bronze
# cards are not progression in vanilla and CoS entry already requires Spongify, so
# owning every bronze card must NOT skip the fall. Spongify stays a hard dependency.
class TestChamberFirstFallVanillaStillNeedsSpongify(HP2TestBase):
    options = {"game_mode": "vanilla", "starting_spells": [], "containersanity": True}
    run_default_tests = False

    def test_cauldron_1_still_needs_spongify(self) -> None:
        self.assertAccessDependency(["Chamber of Secrets - Cauldron 1"],
                                    [["Spongify"]], only_check_listed=True)


# Gold Card Room is gated behind the silver-card collection (40 in vanilla, 20 in
# open castle); with zero silvers it is unreachable, with all of them it opens.
class TestGoldCardRoomSilverGate(HP2TestBase):
    options = {"game_mode": "open_castle", "starting_spells": []}
    run_default_tests = False

    def test_gold_room_needs_silver_cards(self) -> None:
        self.assertAccessDependency(["Gold Card Room - Card Bott"],
                                    [_SILVER_CARD_NAMES], only_check_listed=True)


# Open-castle goal: a spells-only goal must require every spell to complete.
class TestOpenCastleSpellGoal(HP2TestBase):
    options = {
        "game_mode": "open_castle",
        "open_castle_goal_cards": 0,
        "open_castle_goal_spells": 7,
        "open_castle_goal_levels": 0,
        "open_castle_goal_duels": False,
        "open_castle_goal_quidditch": False,
        "starting_spells": [],
    }
    run_default_tests = False

    def test_goal_requires_every_spell(self) -> None:
        without_one = self.state_all_but(["Spongify"])
        self.assertFalse(self.multiworld.can_beat_game(without_one),
                         "a 7-spell goal must not be beatable while a spell is missing")
        with_all = self.state_all_but([])
        self.assertTrue(self.multiworld.can_beat_game(with_all),
                        "the goal must be beatable once every item is collected")


# More Running-off dependencies: without the shortcut the spell chain is real.
class TestMoreRunningOffChains(HP2TestBase):
    options = {"game_mode": "vanilla", "allow_running_logic": False, "starting_spells": []}
    run_default_tests = False

    def test_youdle_needs_spongify(self) -> None:
        self.assertAccessDependency(["Castle Exterior - Card Youdle"],
                                    [["Spongify"]], only_check_listed=True)

    def test_marjoribanks_needs_diffindo(self) -> None:
        self.assertAccessDependency(["Castle Exterior - Card Marjoribanks"],
                                    [["Diffindo"]], only_check_listed=True)


# Vanilla Card Marjoribanks gates on Alohomora and Diffindo plus EITHER the
# spell chain OR Running. Diffindo sits outside the chain, so it is required even
# on the Running shortcut (Running alone does not bypass it).
class TestVanillaMarjoribanksRunningStillNeedsDiffindo(HP2TestBase):
    options = {"game_mode": "vanilla", "allow_running_logic": True, "starting_spells": []}
    run_default_tests = False

    LOC = "Castle Exterior - Card Marjoribanks"

    def test_running_does_not_bypass_diffindo(self) -> None:
        self.assertFalse(
            self.state_all_but(["Diffindo"]).can_reach(self.LOC, "Location", self.player),
            "Marjoribanks needs Diffindo even with Running available")

    def test_reachable_with_full_inventory(self) -> None:
        self.assertTrue(
            self.state_all_but([]).can_reach(self.LOC, "Location", self.player))


# Vanilla Secret 7 gates on Diffindo plus EITHER the spell chain OR Running.
# Diffindo is the always-required gate; Alohomora is NOT required (it gates the
# sibling secrets, not this one).
class TestVanillaSecret7GatedByDiffindoNotAlohomora(HP2TestBase):
    options = {"game_mode": "vanilla", "allow_running_logic": True, "starting_spells": []}
    run_default_tests = False

    LOC = "Castle Exterior - Secret 7"

    def test_diffindo_required(self) -> None:
        self.assertFalse(
            self.state_all_but(["Diffindo"]).can_reach(self.LOC, "Location", self.player),
            "Secret 7 requires Diffindo")

    def test_alohomora_not_required(self) -> None:
        self.assertTrue(
            self.state_all_but(["Alohomora"]).can_reach(self.LOC, "Location", self.player),
            "Secret 7 does not require Alohomora")


# Vendor equipment: vanilla gates Fred's Nimbus behind Rictusempra; open castle
# leaves it unrestricted.
class TestVendorEquipmentVanillaGate(HP2TestBase):
    options = {"game_mode": "vanilla", "enable_quidditch_upgrades": True, "starting_spells": []}
    run_default_tests = False

    def test_nimbus_needs_rictusempra(self) -> None:
        self.assertAccessDependency(["Castle Exterior - Nimbus 2001"],
                                    [["Rictusempra"]], only_check_listed=True)


class TestVendorEquipmentOpenCastleFree(HP2TestBase):
    options = {"game_mode": "open_castle", "enable_quidditch_upgrades": True, "starting_spells": []}
    run_default_tests = False

    def test_nimbus_reachable_without_rictusempra(self) -> None:
        state = self.state_all_but(["Rictusempra"])
        self.assertTrue(
            state.can_reach("Castle Exterior - Nimbus 2001", "Location", self.player),
            "open castle leaves the Nimbus vendor unrestricted")


# Vanilla gates levels in a CUMULATIVE chain (unlike open castle's standalone
# keys): each deeper region needs every earlier level key too. Each chain key is
# therefore independently necessary -> removing any one strands the location.
# assertAccessDependency can't express an AND-chain, so this checks necessity by
# removal. vanilla_gate_levels default-on keeps these chain keys in the pool.
VANILLA_CHAIN = {
    "Boomslang Level - Card Toke":
        ("Bicorn Level Key", "Boomslang Level Key"),
    "Goyle Level - Card Bloxam":
        ("Bicorn Level Key", "Boomslang Level Key", "Goyle Level Key"),
    "Slytherin Common Room - Card Pilliwickle":
        ("Bicorn Level Key", "Boomslang Level Key", "Goyle Level Key",
         "Slytherin Common Room Key"),
    "Forbidden Forest - Card Fancourt":
        ("Bicorn Level Key", "Boomslang Level Key", "Goyle Level Key",
         "Slytherin Common Room Key", "Forbidden Forest Key"),
    "Duelling Club - Duel Rank 1":
        ("Bicorn Level Key", "Duelling Key"),
}


class TestVanillaBlockerChains(HP2TestBase):
    options = {
        "game_mode": "vanilla",
        "starting_spells": [],
        "allow_running_logic": False,
        "enable_duelling": True,
    }
    run_default_tests = False

    def test_every_chain_key_is_necessary(self) -> None:
        for loc, chain in VANILLA_CHAIN.items():
            full = self.state_all_but([])
            self.assertTrue(full.can_reach(loc, "Location", self.player),
                            f"{loc} should be reachable with the whole chain collected")
            for missing in chain:
                state = self.state_all_but([missing])
                self.assertFalse(state.can_reach(loc, "Location", self.player),
                                 f"{loc} reachable without {missing}: vanilla chain not enforced")


# Hub-world vanilla extras. In open castle the hub regions (Entry Hall, Grand
# Staircase) are lightly gated; vanilla layers extra spell requirements on top.
# These pin the vanilla-only extra (and the open castle baseline) so a future
# logic edit cannot silently drop the difference.
class TestEntryHallHubOpenCastleUngated(HP2TestBase):
    options = {"game_mode": "open_castle", "starting_spells": []}
    run_default_tests = False

    def test_gunhilda_needs_only_alohomora(self) -> None:
        # Open castle Entry Hall is unrestricted; the card needs only Alohomora.
        self.assertAccessDependency(["Entry Hall - Card Gunhilda"],
                                    [["Alohomora"]], only_check_listed=True)


class TestEntryHallHubVanillaExtra(HP2TestBase):
    options = {"game_mode": "vanilla", "allow_running_logic": False,
               "starting_spells": [], "containersanity": True}
    run_default_tests = False

    LOC = "Entry Hall - Card Gunhilda"

    def test_vanilla_needs_the_extra(self) -> None:
        # Vanilla adds (Rictusempra OR Skurge+Diffindo) on top of the open rule.
        none_of = self.state_all_but(["Rictusempra", "Skurge", "Diffindo"])
        self.assertFalse(none_of.can_reach(self.LOC, "Location", self.player),
                         "vanilla Gunhilda needs Rictusempra or Skurge+Diffindo")

    def test_rictusempra_alone_satisfies_extra(self) -> None:
        self.assertTrue(
            self.state_all_but(["Skurge", "Diffindo"]).can_reach(self.LOC, "Location", self.player),
            "Rictusempra alone should unlock vanilla Gunhilda")

    def test_skurge_and_diffindo_satisfy_extra(self) -> None:
        self.assertTrue(
            self.state_all_but(["Rictusempra"]).can_reach(self.LOC, "Location", self.player),
            "Skurge + Diffindo should unlock vanilla Gunhilda without Rictusempra")

    def test_knight_3_has_the_same_extra(self) -> None:
        # A non-card Entry Hall location carries the same vanilla extra.
        knight = "Entry Hall - Knight 3"
        self.assertFalse(
            self.state_all_but(["Rictusempra", "Skurge", "Diffindo"]).can_reach(
                knight, "Location", self.player),
            "vanilla Knight 3 needs Rictusempra or Skurge+Diffindo")
        self.assertTrue(
            self.state_all_but(["Skurge", "Diffindo"]).can_reach(knight, "Location", self.player),
            "Rictusempra alone should unlock vanilla Knight 3")


class TestGrandStaircaseHubVanillaExtra(HP2TestBase):
    options = {"game_mode": "vanilla", "allow_running_logic": False,
               "starting_spells": [], "containersanity": True}
    run_default_tests = False

    def test_barkwith_needs_rictusempra(self) -> None:
        # Vanilla adds Rictusempra; open castle needs only its open rule.
        self.assertAccessDependency(["Grand Staircase - Card Barkwith"],
                                    [["Rictusempra"]], only_check_listed=True)

    def test_blane_needs_rictusempra_and_skurge(self) -> None:
        loc = "Grand Staircase - Card Blane"
        self.assertFalse(self.state_all_but(["Rictusempra"]).can_reach(loc, "Location", self.player),
                         "vanilla Blane needs Rictusempra")
        self.assertFalse(self.state_all_but(["Skurge"]).can_reach(loc, "Location", self.player),
                         "vanilla Blane needs Skurge")
        self.assertTrue(self.state_all_but([]).can_reach(loc, "Location", self.player),
                        "Blane reachable with the full inventory")

    def test_cauldron_3_needs_rictusempra_and_skurge(self) -> None:
        # A non-card hub location with the same vanilla extra as Blane.
        loc = "Grand Staircase - Cauldron 3"
        self.assertFalse(self.state_all_but(["Rictusempra"]).can_reach(loc, "Location", self.player),
                         "vanilla Cauldron 3 needs Rictusempra")
        self.assertFalse(self.state_all_but(["Skurge"]).can_reach(loc, "Location", self.player),
                         "vanilla Cauldron 3 needs Skurge")
        self.assertTrue(self.state_all_but([]).can_reach(loc, "Location", self.player),
                        "Cauldron 3 reachable with the full inventory")


# The three _VANILLA_OVERRIDE locations are where vanilla is NOT a clean superset
# of the open castle rule, so vanilla carries its rule in full. Pin each mode so
# the override cannot silently drift. (Card Youdle is covered above.)
class TestVanillaSecret6Override(HP2TestBase):
    options = {"game_mode": "vanilla", "allow_running_logic": False, "starting_spells": []}
    run_default_tests = False

    LOC = "Castle Exterior - Secret 6"

    def test_vanilla_needs_the_chain_without_running(self) -> None:
        self.assertTrue(self.state_all_but([]).can_reach(self.LOC, "Location", self.player),
                        "reachable with the full chain")
        for missing in ("Skurge", "Rictusempra", "Bicorn Level Key"):
            self.assertFalse(self.state_all_but([missing]).can_reach(self.LOC, "Location", self.player),
                             f"vanilla Secret 6 reachable without {missing}")


class TestOpenCastleSecret6Ungated(HP2TestBase):
    options = {"game_mode": "open_castle", "allow_running_logic": False, "starting_spells": []}
    run_default_tests = False

    def test_reachable_via_spongify_without_flipendo(self) -> None:
        state = self.state_all_but(["Flipendo"])
        self.assertTrue(state.can_reach("Castle Exterior - Secret 6", "Location", self.player),
                        "open castle Secret 6 reaches via Spongify without Flipendo")


# Card Vablatsky is the one location where the two modes genuinely diverge:
# vanilla gates on Rictusempra + Skurge, open castle on the Chamber of Secrets Key.
class TestVablatskyVanilla(HP2TestBase):
    options = {"game_mode": "vanilla", "starting_spells": []}
    run_default_tests = False

    def test_needs_rictusempra_and_skurge(self) -> None:
        self.assertAccessDependency(["Grand Staircase - Card Vablatsky"],
                                    [["Rictusempra", "Skurge"]], only_check_listed=True)


class TestVablatskyOpenCastle(HP2TestBase):
    options = {"game_mode": "open_castle", "starting_spells": []}
    run_default_tests = False

    def test_needs_chamber_key(self) -> None:
        self.assertAccessDependency(["Grand Staircase - Card Vablatsky"],
                                    [["Chamber of Secrets Key"]], only_check_listed=True)


# Duelling / Quidditch keys gate only their own category's region. When the
# category is off and the key is not an open castle goal requirement, the key is
# precollected (granted at start, no bookcase) instead of sitting in the pool
# gating an empty region. When the category is on, or the open castle goal needs
# the key, it stays a found item.
class TestDuellingKeyPrecollectedWhenOff(HP2TestBase):
    options = {"game_mode": "vanilla", "enable_duelling": False}
    run_default_tests = False

    def test_key_precollected_not_pooled(self) -> None:
        pool = {item.name for item in self.multiworld.itempool}
        precollected = {item.name for item in self.multiworld.precollected_items[self.player]}
        self.assertNotIn("Duelling Key", pool, "duels off: the key must not sit in the pool")
        self.assertIn("Duelling Key", precollected, "duels off: the key must be precollected")


class TestQuidditchKeyPrecollectedWhenOff(HP2TestBase):
    options = {"game_mode": "vanilla", "enable_quidditch_matches": False}
    run_default_tests = False

    def test_key_precollected_not_pooled(self) -> None:
        pool = {item.name for item in self.multiworld.itempool}
        precollected = {item.name for item in self.multiworld.precollected_items[self.player]}
        self.assertNotIn("Quidditch Key", pool, "matches off: the key must not sit in the pool")
        self.assertIn("Quidditch Key", precollected, "matches off: the key must be precollected")


class TestDuellingKeyPooledWhenOn(HP2TestBase):
    options = {"game_mode": "vanilla", "enable_duelling": True}
    run_default_tests = False

    def test_key_pooled_not_precollected(self) -> None:
        pool = {item.name for item in self.multiworld.itempool}
        precollected = {item.name for item in self.multiworld.precollected_items[self.player]}
        self.assertIn("Duelling Key", pool, "duels on: the key gates real checks, so it stays in the pool")
        self.assertNotIn("Duelling Key", precollected)


# The deliberate payoff: in open castle the Duelling Club is standalone-gated, so
# precollecting its key opens the region from spawn and the bean-grind OR-path to
# the costly vendors is reachable in sphere 0.
class TestDuellingKeyOpenCastleReachableFromStart(HP2TestBase):
    options = {"game_mode": "open_castle", "enable_duelling": False}
    run_default_tests = False

    def test_duelling_club_reachable_with_only_precollected(self) -> None:
        precollected = [item.name for item in self.multiworld.precollected_items[self.player]]
        self.assertIn("Duelling Key", precollected)
        state = self.state_with(precollected)
        self.assertTrue(
            state.can_reach("DuellingClub", "Region", self.player),
            "a precollected Duelling Key should open the club from spawn for the bean grind")


# Open castle goal requires the Duelling Key while duels are NOT randomized: the
# key must stay a found item (precollecting it would beat the goal for free), and
# the seed must still be solvable.
class TestDuellingKeyPooledWhenGoalRequiresIt(HP2TestBase):
    options = {
        "game_mode": "open_castle",
        "enable_duelling": False,
        "open_castle_goal_cards": 0,
        "open_castle_goal_spells": 0,
        "open_castle_goal_levels": 0,
        "open_castle_goal_duels": True,
        "open_castle_goal_quidditch": False,
    }
    run_default_tests = False

    def test_key_pooled_not_precollected(self) -> None:
        pool = {item.name for item in self.multiworld.itempool}
        precollected = {item.name for item in self.multiworld.precollected_items[self.player]}
        self.assertIn("Duelling Key", pool, "the goal needs the key found, so it stays in the pool")
        self.assertNotIn("Duelling Key", precollected)

    def test_goal_needs_the_key(self) -> None:
        without_key = self.state_all_but(["Duelling Key"])
        self.assertFalse(self.multiworld.can_beat_game(without_key),
                         "the duels goal must not be beatable without the Duelling Key")
        self.assertTrue(self.multiworld.can_beat_game(self.state_all_but([])),
                        "the goal must be beatable once every item is collected")
