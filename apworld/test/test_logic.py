"""Targeted access-rule tests that pin specific logic/data behaviors so a future
logic edit can't silently break them: bookcase/level blocker keys, per-category
location gating, and the Running-logic shortcut."""

from BaseClasses import CollectionState

from .bases import HP2TestBase
from ..access import _BRONZE_CARD_NAMES, _SILVER_CARD_NAMES


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
    # and Skurge on top of its non-skippable Spongify.
    def _state_with(self, names: list[str]) -> CollectionState:
        state = CollectionState(self.multiworld)
        for name in names:
            state.collect(self.world.create_item(name), prevent_sweep=True)
        return state

    def test_twenty_bronze_skips_first_fall(self) -> None:
        state = self._state_with(
            ["Chamber of Secrets Key", "Alohomora", "Flipendo"] + _BRONZE_CARD_NAMES[:20])
        self.assertTrue(
            state.can_reach("Chamber of Secrets - Cauldron 1", "Location", self.player),
            "20 bronze cards should let Harry tank the first fall without Spongify")

    def test_nineteen_bronze_is_not_enough(self) -> None:
        state = self._state_with(
            ["Chamber of Secrets Key", "Alohomora", "Flipendo"] + _BRONZE_CARD_NAMES[:19])
        self.assertFalse(
            state.can_reach("Chamber of Secrets - Cauldron 1", "Location", self.player),
            "19 bronze cards is below the fall-survival threshold")

    def test_spongify_still_reaches_first_fall_without_bronze(self) -> None:
        state = self._state_with(
            ["Chamber of Secrets Key", "Alohomora", "Flipendo", "Spongify"])
        self.assertTrue(
            state.can_reach("Chamber of Secrets - Cauldron 1", "Location", self.player),
            "Spongify remains a valid path for the first fall")

    def test_bronze_does_not_skip_a_deeper_spongify_gate(self) -> None:
        state = self._state_with(
            ["Chamber of Secrets Key", "Alohomora", "Flipendo", "Diffindo", "Skurge"]
            + _BRONZE_CARD_NAMES[:20])
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
            full = CollectionState(self.multiworld)
            self.collect_all_but([], full)
            self.assertTrue(full.can_reach(loc, "Location", self.player),
                            f"{loc} should be reachable with the whole chain collected")
            for missing in chain:
                state = CollectionState(self.multiworld)
                self.collect_all_but([missing], state)
                self.assertFalse(state.can_reach(loc, "Location", self.player),
                                 f"{loc} reachable without {missing}: vanilla chain not enforced")
