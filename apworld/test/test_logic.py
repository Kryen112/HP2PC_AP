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


# The same lit/dark sibling logic applies in the Bicorn Level: Chest 8 is the dark
# chest (Lumos on top of the lit-area set), while Chest 5 is lit (no Lumos). Pin
# both so a future edit cannot silently move or drop the Lumos gate between them.
# Same isolation as the Goyle test above.
class TestBicornChest8NeedsLumosChest5DoesNot(HP2TestBase):
    options = {
        "game_mode": "open_castle",
        "starting_spells": [],
        "allow_running_logic": False,
        "containersanity": True,
    }
    run_default_tests = False

    def test_chest_8_needs_lumos(self) -> None:
        self.assertAccessDependency(["Bicorn Level - Chest 8"],
                                    [["Lumos"]], only_check_listed=True)

    def test_chest_5_does_not_need_lumos(self) -> None:
        state = self.state_all_but(["Lumos"])
        self.assertTrue(
            state.can_reach("Bicorn Level - Chest 5", "Location", self.player),
            "Bicorn Chest 5 is a lit-area chest and must not require Lumos")


# Rictusempra Challenge - Chest 5 sits in a dark spot, so its rule adds Lumos on top
# of the lit-area set, unlike sibling Chests 1-4 and 6. Pin both sides so a future
# edit cannot silently drop the Lumos gate or spread it to the lit chests. Same
# isolation as the Bicorn/Goyle chest tests above.
class TestRictusempraChest5NeedsLumos(HP2TestBase):
    options = {
        "game_mode": "open_castle",
        "starting_spells": [],
        "allow_running_logic": False,
        "containersanity": True,
    }
    run_default_tests = False

    def test_chest_5_needs_lumos(self) -> None:
        self.assertAccessDependency(["Rictusempra Challenge - Chest 5"],
                                    [["Lumos"]], only_check_listed=True)

    def test_chest_4_does_not_need_lumos(self) -> None:
        state = self.state_all_but(["Lumos"])
        self.assertTrue(
            state.can_reach("Rictusempra Challenge - Chest 4", "Location", self.player),
            "Rictusempra Chest 4 is a lit-area chest and must not require Lumos")


# Skurge Challenge - Complete accepts Running in place of Lumos, matching its
# sibling Skurge locations whose lit-area gate is (Lumos OR Running). With Running
# on, the finish is reachable without Lumos; with Running off, Lumos stays the only
# path. starting_spells empty so Lumos sits in the pool rather than precollected.
class TestSkurgeCompleteRunningSubsForLumos(HP2TestBase):
    options = {"game_mode": "open_castle", "allow_running_logic": True, "starting_spells": []}
    run_default_tests = False

    def test_complete_reachable_without_lumos_via_running(self) -> None:
        state = self.state_all_but(["Lumos"])
        self.assertTrue(
            state.can_reach("Skurge Challenge - Complete", "Location", self.player),
            "Running should let Skurge Challenge - Complete finish without Lumos")


class TestSkurgeCompleteNeedsLumosWithoutRunning(HP2TestBase):
    options = {"game_mode": "open_castle", "allow_running_logic": False, "starting_spells": []}
    run_default_tests = False

    def test_complete_needs_lumos_without_running(self) -> None:
        self.assertAccessDependency(["Skurge Challenge - Complete"],
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
        state = self.state_all_but(["Rictusempra", "Skurge", "Progressive Level Key"])
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


# Cauldron 10, Flobberworm Mucous Jar 3, and Wiggentree Bark Jar 3 sit in the deep
# chamber behind the full spell set, matching Cauldron 8/9, Mucous Jar 2, and Bark
# Jar 2. Pin each spell individually so a future edit cannot silently loosen one of
# these back to bare Flipendo. Region entry (Chamber of Secrets Key + Alohomora)
# stays collected, so the five spells are the isolated gate.
class TestChamberDeepSetNeedsFullSpellSet(HP2TestBase):
    options = {
        "game_mode": "open_castle",
        "starting_spells": [],
        "allow_running_logic": False,
        "containersanity": True,
    }
    run_default_tests = False

    DEEP_SET = ["Spongify", "Diffindo", "Skurge", "Rictusempra", "Flipendo"]
    LOCATIONS = [
        "Chamber of Secrets - Cauldron 10",
        "Chamber of Secrets - Flobberworm Mucous Jar 3",
        "Chamber of Secrets - Wiggentree Bark Jar 3",
    ]

    def test_each_deep_location_needs_every_spell(self) -> None:
        # One dependency per spell: dropping any single one (Flipendo included)
        # must strand the location, so a loosen back to bare Flipendo is caught.
        for loc in self.LOCATIONS:
            for spell in self.DEEP_SET:
                self.assertAccessDependency([loc], [[spell]], only_check_listed=True)


# Gold Card Room is gated behind the silver-card collection (40 in vanilla, 20 in
# open castle); with zero silvers it is unreachable, with all of them it opens.
class TestGoldCardRoomSilverGate(HP2TestBase):
    options = {"game_mode": "open_castle", "starting_spells": []}
    run_default_tests = False

    def test_gold_room_needs_silver_cards(self) -> None:
        self.assertAccessDependency(["Gold Card Room - Card Bott"],
                                    [_SILVER_CARD_NAMES], only_check_listed=True)


# The Gold Card Room's deep section sits past a dark, Flipendo-gated passage, so
# the five cards back there plus Complete need Lumos and Flipendo on top of the
# skurge cards' rule. Vanilla masks this (its region entry already needs
# lumos & flipendo); open castle enters on silver cards alone, so without the
# per-card gate the deep cards read as reachable while missing both spells. The
# shallow skurge card (Hufflepuff) is reachable without Lumos and pins the split.
class TestGoldCardRoomDeepLumosFlipendo(HP2TestBase):
    options = {"game_mode": "open_castle", "starting_spells": []}
    run_default_tests = False

    DEEP = [
        "Gold Card Room - Card Knightley",
        "Gold Card Room - Card Paracelsus",
        "Gold Card Room - Card Pinkstone",
        "Gold Card Room - Card Potter",
        "Gold Card Room - Card Ravenclaw",
        "Gold Card Room - Complete",
    ]

    def test_deep_cards_need_lumos_and_flipendo(self) -> None:
        for spell in ("Lumos", "Flipendo"):
            self.assertAccessDependency(self.DEEP, [[spell]], only_check_listed=True)

    def test_shallow_skurge_card_reachable_without_lumos(self) -> None:
        state = self.state_all_but(["Lumos"])
        self.assertTrue(
            state.can_reach("Gold Card Room - Card Hufflepuff", "Location", self.player),
            "Hufflepuff is in the lit section and must not require Lumos",
        )


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
# keys), modelled as Progressive Level Key copies: the Nth copy unlocks the Nth
# level in story order. With vanilla_gate_levels default-on the pool carries 5
# copies and none of the named story keys. One representative location per
# chain level, in unlock order.
VANILLA_CHAIN_LOCATIONS = [
    "Bicorn Level - Card Agrippa",
    "Boomslang Level - Card Toke",
    "Goyle Level - Card Bloxam",
    "Slytherin Common Room - Card Pilliwickle",
    "Forbidden Forest - Card Fancourt",
]


class TestVanillaProgressiveChain(HP2TestBase):
    options = {
        "game_mode": "vanilla",
        "starting_spells": [],
        "allow_running_logic": False,
        "enable_duelling": True,
    }
    run_default_tests = False

    def test_pool_swaps_named_story_keys_for_progressive(self) -> None:
        pool = [item.name for item in self.multiworld.itempool]
        precollected = {item.name for item in self.multiworld.precollected_items[self.player]}
        self.assertEqual(pool.count("Progressive Level Key"), 5,
                         "vanilla gate-on pools exactly 5 progressive key copies")
        for named in ("Bicorn Level Key", "Boomslang Level Key", "Goyle Level Key",
                      "Slytherin Common Room Key", "Forbidden Forest Key"):
            self.assertNotIn(named, pool, f"{named} must not sit in the pool")
            self.assertNotIn(named, precollected, f"{named} must not be precollected")

    def test_duelling_and_quidditch_keys_stay_named(self) -> None:
        pool = [item.name for item in self.multiworld.itempool]
        self.assertIn("Duelling Key", pool, "the Duelling Key stays a named pool item")

    def test_each_copy_unlocks_the_next_level(self) -> None:
        state = self.state_all_but(["Progressive Level Key"])
        for loc in VANILLA_CHAIN_LOCATIONS:
            self.assertFalse(state.can_reach(loc, "Location", self.player),
                             f"{loc} reachable with 0 progressive keys")
        for copies, loc in enumerate(VANILLA_CHAIN_LOCATIONS, start=1):
            state.collect(self.world.create_item("Progressive Level Key"), prevent_sweep=True)
            self.assertTrue(state.can_reach(loc, "Location", self.player),
                            f"{loc} should open at {copies} progressive key(s)")
            if copies < len(VANILLA_CHAIN_LOCATIONS):
                deeper = VANILLA_CHAIN_LOCATIONS[copies]
                self.assertFalse(state.can_reach(deeper, "Location", self.player),
                                 f"{deeper} must stay locked at {copies} progressive key(s)")

    def test_duelling_club_needs_first_key_and_duelling_key(self) -> None:
        loc = "Duelling Club - Duel Rank 1"
        without_duelling = self.state_all_but(["Duelling Key"])
        self.assertFalse(without_duelling.can_reach(loc, "Location", self.player),
                         "the Duelling Club still needs its own named key")
        without_progressive = self.state_all_but(["Progressive Level Key"])
        self.assertFalse(without_progressive.can_reach(loc, "Location", self.player),
                         "the Duelling Club needs the first chain unlock")
        without_progressive.collect(
            self.world.create_item("Progressive Level Key"), prevent_sweep=True)
        self.assertTrue(without_progressive.can_reach(loc, "Location", self.player),
                        "one progressive key plus the Duelling Key opens the club")


# vanilla_gate_levels off: the classic flow. All named keys are precollected,
# nothing is progressive, and every story region opens from the start.
class TestVanillaGateLevelsOffKeepsNamedKeys(HP2TestBase):
    options = {"game_mode": "vanilla", "vanilla_gate_levels": False, "starting_spells": []}
    run_default_tests = False

    def test_named_keys_precollected_no_progressive(self) -> None:
        pool = [item.name for item in self.multiworld.itempool]
        precollected = {item.name for item in self.multiworld.precollected_items[self.player]}
        self.assertNotIn("Progressive Level Key", pool)
        self.assertNotIn("Progressive Level Key", precollected)
        for named in ("Bicorn Level Key", "Boomslang Level Key", "Goyle Level Key",
                      "Slytherin Common Room Key", "Forbidden Forest Key"):
            self.assertIn(named, precollected, f"{named} must be precollected with gating off")
            self.assertNotIn(named, pool)

    def test_chain_locations_reachable_without_progressive(self) -> None:
        state = self.state_all_but(["Progressive Level Key"])
        for loc in VANILLA_CHAIN_LOCATIONS:
            self.assertTrue(state.can_reach(loc, "Location", self.player),
                            f"{loc} should be open with gating off")


# Open castle is untouched by the progressive conversion: every named key stays
# a standalone pool item and no progressive copy exists.
class TestOpenCastleKeepsNamedKeys(HP2TestBase):
    options = {"game_mode": "open_castle", "starting_spells": []}
    run_default_tests = False

    def test_named_keys_pooled_no_progressive(self) -> None:
        pool = [item.name for item in self.multiworld.itempool]
        self.assertNotIn("Progressive Level Key", pool)
        for named in ("Bicorn Level Key", "Boomslang Level Key", "Goyle Level Key",
                      "Slytherin Common Room Key", "Forbidden Forest Key"):
            self.assertIn(named, pool, f"{named} must stay a pool item in open castle")


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
        for missing in ("Skurge", "Rictusempra", "Progressive Level Key"):
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
