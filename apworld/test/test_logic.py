"""Targeted access-rule tests that pin specific logic/data behaviors so a future
logic edit can't silently break them: bookcase/level blocker keys, per-category
location gating, and the Running-logic shortcut."""

from BaseClasses import CollectionState

from .bases import HP2TestBase
from ..rules import _SILVER_CARD_NAMES


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
        self.world.get_location("Castle Exterior - Nimbus 2001")
        self.world.get_location("Castle Exterior - Quidditch Armour")


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
        self.world.get_location("Duelling Club - Duel Rank 1")


class TestDuellingOffAbsent(HP2TestBase):
    options = {"game_mode": "vanilla", "enable_duelling": False}
    run_default_tests = False

    def test_duel_locations_absent(self) -> None:
        self.assertRaises(KeyError, self.world.get_location, "Duelling Club - Duel Rank 1")


class TestQuidditchMatchesTogglePresence(HP2TestBase):
    options = {"game_mode": "vanilla", "enable_quidditch_matches": True}
    run_default_tests = False

    def test_match_locations_present(self) -> None:
        self.world.get_location("Quidditch - Match 1 (Hufflepuff)")


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
        state = CollectionState(self.multiworld)
        self.collect_all_but(["Rictusempra", "Skurge", "Bicorn Level Key"], state)
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
        without_one = CollectionState(self.multiworld)
        self.collect_all_but(["Spongify"], without_one)
        self.assertFalse(self.multiworld.can_beat_game(without_one),
                         "a 7-spell goal must not be beatable while a spell is missing")
        with_all = CollectionState(self.multiworld)
        self.collect_all_but([], with_all)
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
        state = CollectionState(self.multiworld)
        self.collect_all_but(["Rictusempra"], state)
        self.assertTrue(
            state.can_reach("Castle Exterior - Nimbus 2001", "Location", self.player),
            "open castle leaves the Nimbus vendor unrestricted")
