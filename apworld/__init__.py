"""HP2PC_AP — Harry Potter 2: Chamber of Secrets PC randomizer for Archipelago.

Items + locations come from data/*.yaml. The .py files in this directory
are auto-generated; treat data/*.yaml as the source of truth.

Generation models the Basilisk goal as the item/logic requirements needed to
reach endgame. Runtime completion comes from the game-side GOAL_COMPLETE signal
when credits start after the Basilisk sequence.
"""

from __future__ import annotations

import random as _random
from dataclasses import dataclass
from typing import Any

from BaseClasses import (CollectionState, Item, ItemClassification, Location,
                         LocationProgressType, Region)
from Options import (Choice, DefaultOnToggle, OptionSet, PerGameCommonOptions,
                     StartInventoryPool, Toggle)
from worlds.AutoWorld import WebWorld, World
from worlds.LauncherComponents import Component, Type, components
from worlds.LauncherComponents import launch as launch_component

from .items import BASE_ID as ITEM_BASE_ID
from .items import (CARD_CLASS_TO_ITEM_NAME, FILLER_NAMES,
                    ITEM_CLASSIFICATIONS, ITEM_GROUPS, ITEM_NAME_TO_ID)
from .locations import BASE_ID as LOCATION_BASE_ID
from .locations import (CARD_CLASS_TO_LOCATION_NAME,
                        CARD_GAME_ID_TO_LOCATION_NAME,
                        MISSABLE_SECRET_DEPS_BINGO,
                        MISSABLE_SECRET_DEPS_VANILLA, MISSABLE_SECRETS,
                        LOCATION_GROUPS, LOCATION_NAME_TO_ID, LOCATION_REGIONS)
from .regions import (REGION_ENTRY_RULES_BINGO, REGION_ENTRY_RULES_VANILLA,
                      REGION_NAMES, START_REGION)
from .rules import (GOAL_LOCATION_REQUIREMENTS_BINGO,
                    GOAL_LOCATION_REQUIREMENTS_VANILLA, GOAL_RULES_BINGO,
                    GOAL_RULES_VANILLA, LOCATION_RULES_BINGO,
                    LOCATION_RULES_VANILLA)

PROGRESSION_ITEM_NAMES: list[str] = [
    name for name, c in ITEM_CLASSIFICATIONS.items() if c == ItemClassification.progression
]

DEFAULT_GOAL = "basilisk"
SPELL_ITEM_NAMES: list[str] = sorted(ITEM_GROUPS.get("Spells", []))
# Level-entry keys. In bingo, all 13 are AP items gating every level
# transition. In vanilla with vanilla_gate_levels on, the 7 in
# VANILLA_BLOCKED_KEY_NAMES are also AP items (the mod spawns a bookcase
# blocking each region until the key arrives) and the other 6 are
# precollected so their logic.yaml terms pass trivially without entering the
# pool. With vanilla_gate_levels off, all 13 are precollected and no bookcase
# spawns.
BINGO_KEY_NAMES: set[str] = set(ITEM_GROUPS.get("Bingo Keys", []))
# Keys that gate a region behind a bookcase in vanilla when
# vanilla_gate_levels is on (linear story order).
# Bicorn/Boomslang/Goyle/Slytherin/Forbidden Forest are a cumulative chain (a
# region needs its own key plus every earlier level key); Duelling and
# Quidditch are standalone (own key only, gating just their duels / matches).
# The other 6 keys are always vanilla-precollected.
VANILLA_BLOCKED_KEY_NAMES: set[str] = {
    "Bicorn Level Key", "Boomslang Level Key", "Goyle Level Key",
    "Slytherin Common Room Key", "Forbidden Forest Key",
    "Duelling Key", "Quidditch Key",
}


def launch_client(*args: str) -> None:
    # Lazy-import Client so apworld registration (this module's import side
    # effects) doesn't pull in CommonClient / colorama / kivy until the user
    # actually clicks the launcher button.
    from .Client import launch
    launch_component(launch, name="HP2 PC Client", args=args)


components.append(Component(
    "HP2 PC Client",
    func=launch_client,
    component_type=Type.CLIENT,
    game_name="Harry Potter 2 PC",
    supports_uri=True,
    description="Connect to a multiworld and bridge to the HP2 PC mod.",
))


class HP2Item(Item):
    game = "Harry Potter 2 PC"


class HP2Location(Location):
    game = "Harry Potter 2 PC"


class HP2WebWorld(WebWorld):
    """Web frontend metadata for archipelago.gg."""


class GameMode(Choice):
    """Which install layout this seed targets.

    `vanilla` (default): retail HP2 + M212 patch — the normal story flow.
    Whether the 7 region keys gate their regions behind bookcases or are
    precollected is governed by `vanilla_gate_levels`; the other 6 keys are
    always precollected here.

    `bingo`: the bingo-distribution maps (open castle, every door unlocked).
    The 13 bingo keys are AP items gating each level transition.

    Which spells Harry starts with is governed by `starting_spells`;
    `vanilla_gate_levels` governs the 7 region keys. Neither is set by this
    option.
    """
    display_name = "Game Mode"
    option_vanilla = 0
    option_bingo = 1
    default = 0


class VanillaGateLevels(DefaultOnToggle):
    """Vanilla only. If true, the 7 region keys (Bicorn, Boomslang, Goyle,
    Slytherin Common Room, Forbidden Forest, Duelling, Quidditch) are AP items:
    the mod spawns a bookcase blocking each region until its key arrives, and
    the 5 level regions form a cumulative chain (each needs its own key plus
    every earlier level key, matching vanilla's linear story order).

    If false, those 7 keys are precollected instead, so the regions open
    immediately and no bookcases spawn — the classic precollect-everything
    vanilla flow. Has no effect in bingo mode (all 13 keys are always AP items
    there).
    """
    display_name = "Vanilla gate levels"


class StartingSpells(OptionSet):
    """Spells Harry starts with. Any spell not listed is an AP item instead.

    `vanilla` game_mode physically requires Lumos and Flipendo to finish the
    Whomping Willow level. If left blank for `vanilla`, Lumos and Flipendo are
    granted anyways.

    Valid spells: Alohomora, Flipendo, Lumos, Rictusempra, Skurge, Diffindo & Spongify.
    """
    display_name = "Starting Spells"
    valid_keys = frozenset(SPELL_ITEM_NAMES)
    default = frozenset({"Flipendo", "Lumos", "Alohomora"})


class EnableWizardCards(DefaultOnToggle):
    """If true, the 101 wizard cards become AP locations.
    """
    display_name = "Enable Wizard Cards"


class EnableSecrets(DefaultOnToggle):
    """If true, the 109 Secrets become AP locations.

    Pair with `allow_secrets_progression`for the missable-vs-replayable
    progression eligibility split.
    """
    display_name = "Enable Secrets"


class AllowSecretsProgression(Toggle):
    """If true (and `enable_secrets` is true), missable secrets in
    un-replayable levels (Willow, Bicorn, Boomslang, Goyle, Slytherin Common,
    Forest, Chamber) are allowed to hold progression items.

    If false, missable secrets are filler-only, which is safer because the
    player can't soft-lock by missing a story-replay secret. Replayable
    secrets (Hogwarts, Castle Exterior, the 4 spell challenges) always allow
    progression regardless of this setting; this flag only gates the
    un-replayable subset.
    """
    display_name = "Allow Secrets progression"


class EnableChallengeStars(DefaultOnToggle):
    """If true, the 44 Challenge Stars across the 4 spell-challenges
    (Rictusempra, Skurge, Diffindo, Spongify) become AP locations.
    """
    display_name = "Enable Challenge Stars"


class EnableDuelling(Toggle):
    """If true, each of the 10 duels at the Dueling Club become a location.
    """
    display_name = "Enable Duelling"


class EnableQuidditchMatches(Toggle):
    """If true, each of the 6 Quidditch matches becomes a location.
    """
    display_name = "Enable Quidditch matches"


class EnableQuidditchUpgrades(Toggle):
    """If true, the Nimbus 2001 from Fred and the Quidditch Armour from George
    become locations.
    """
    display_name = "Enable Quidditch upgrades"


@dataclass
class HP2Options(PerGameCommonOptions):
    # PerGameCommonOptions includes start_inventory (just-add) but NOT
    # StartInventoryPool (add-and-remove-from-pool). Keep it available for
    # playtest YAMLs; v1's three starter spells are precollected by the world.
    start_inventory_from_pool: StartInventoryPool
    game_mode: GameMode
    vanilla_gate_levels: VanillaGateLevels
    starting_spells: StartingSpells
    # Per-category check toggles. Each gates both the matching locations and
    # any paired items (currently: wizard cards, vendor equipment) — generator
    # emits both sides into the stable id space, HP2World filters at build
    # time. Spells + classrooms have no toggle: a spell-randomized run is the
    # core experience, so spells are always in the pool and classrooms are
    # always seed locations. With every toggle false the seed has only the 4
    # classrooms and 4 non-starter spells.
    enable_wizard_cards: EnableWizardCards
    enable_secrets: EnableSecrets
    allow_secrets_progression: AllowSecretsProgression
    enable_challenge_stars: EnableChallengeStars
    enable_quidditch_upgrades: EnableQuidditchUpgrades
    enable_duelling: EnableDuelling
    enable_quidditch_matches: EnableQuidditchMatches


class HP2World(World):
    """Harry Potter and the Chamber of Secrets (PC) randomizer."""

    game = "Harry Potter 2 PC"
    web = HP2WebWorld()
    options_dataclass = HP2Options

    item_name_to_id = ITEM_NAME_TO_ID
    location_name_to_id = LOCATION_NAME_TO_ID
    item_name_groups = ITEM_GROUPS

    def create_item(self, name: str) -> HP2Item:
        return HP2Item(name, ITEM_CLASSIFICATIONS[name], self.item_name_to_id[name], self.player)

    def get_filler_item_name(self) -> str:
        # AP calls this when extra items are needed (e.g. start_inventory_from_pool
        # shrunk the pool). Default would pick any item name including cards,
        # producing card duplicates in the seed. Restrict to bean tiers.
        return self.multiworld.random.choice(FILLER_NAMES)

    # Location-group → option-attr map. Locations whose group is in this map
    # and whose corresponding option is False are filtered out of the seed.
    # The Classrooms group has a bingo-mode special case in _location_enabled:
    # the spell-teaching cutscenes are tied to the vanilla story flow that
    # bingo's open castle skips, so those 4 checks are unreachable in bingo
    # and get dropped entirely (their spells stay in the pool, placed elsewhere).
    _LOC_GROUP_TO_OPT: dict[str, str] = {
        "CardLocations":      "enable_wizard_cards",
        "Secrets":            "enable_secrets",
        "ChallengeStars":     "enable_challenge_stars",
        "QuidditchPurchases": "enable_quidditch_upgrades",
        "Duels":              "enable_duelling",
        "QuidditchMatches":   "enable_quidditch_matches",
    }
    # Item-group → option-attr map. Same shape, applies to paired items.
    # Spells / Key Items / Filler aren't listed — always in the pool.
    _ITEM_GROUP_TO_OPT: dict[str, str] = {
        "Cards (Bronze)": "enable_wizard_cards",
        "Cards (Silver)": "enable_wizard_cards",
        "Cards (Gold)":   "enable_wizard_cards",
        "Equipment":      "enable_quidditch_upgrades",
    }

    def _is_bingo(self) -> bool:
        return self.options.game_mode.current_key == "bingo"

    def _region_rules(self) -> dict:
        return REGION_ENTRY_RULES_BINGO if self._is_bingo() else REGION_ENTRY_RULES_VANILLA

    def _location_rules(self) -> dict:
        return LOCATION_RULES_BINGO if self._is_bingo() else LOCATION_RULES_VANILLA

    def _goal_rules(self) -> dict:
        return GOAL_RULES_BINGO if self._is_bingo() else GOAL_RULES_VANILLA

    def _goal_location_requirements(self) -> dict:
        return GOAL_LOCATION_REQUIREMENTS_BINGO if self._is_bingo() else GOAL_LOCATION_REQUIREMENTS_VANILLA

    def _location_enabled(self, loc_name: str) -> bool:
        group = LOCATION_GROUPS.get(loc_name)
        if group == "Classrooms" and self._is_bingo():
            return False
        opt_attr = self._LOC_GROUP_TO_OPT.get(group or "")
        if opt_attr is None:
            return True
        return bool(getattr(self.options, opt_attr))

    def _item_enabled(self, item_name: str) -> bool:
        for group_name, opt_attr in self._ITEM_GROUP_TO_OPT.items():
            if item_name in ITEM_GROUPS.get(group_name, []):
                return bool(getattr(self.options, opt_attr))
        return True

    def create_regions(self) -> None:
        # Build every region declared in logic.yaml plus a "TBD" placeholder for
        # cards whose vanilla home is still uncatalogued. TBD is reachable from
        # Menu with no requirement so seed gen succeeds during playtest.
        all_region_names = list(REGION_NAMES)
        if "TBD" not in all_region_names:
            all_region_names.append("TBD")

        regions_by_name: dict[str, Region] = {}
        for region_name in all_region_names:
            r = Region(region_name, self.player, self.multiworld)
            regions_by_name[region_name] = r
            self.multiworld.regions.append(r)

        start = regions_by_name[START_REGION]
        for region_name, region in regions_by_name.items():
            if region_name == START_REGION:
                continue
            rule_fn = self._region_rules().get(region_name)
            if rule_fn is None:
                start.connect(region)
            else:
                start.connect(
                    region,
                    rule=lambda state, fn=rule_fn, player=self.player: fn(state, player),
                )

        for loc_name, region_name in LOCATION_REGIONS.items():
            if not self._location_enabled(loc_name):
                continue
            r = regions_by_name.get(region_name) or regions_by_name["TBD"]
            loc_id = LOCATION_NAME_TO_ID[loc_name]
            r.locations.append(HP2Location(self.player, loc_name, loc_id, r))

    def _starter_names(self) -> set[str]:
        # Precollected = the spells the player chose via `starting_spells`,
        # plus (vanilla only) all 13 bingo level-entry keys so logic.yaml
        # references to them auto-pass without entering the vanilla pool.
        # Bingo keeps the keys in the pool — the mod-side bookcases gate each
        # level transition until the matching key arrives via the AP grant.
        spells = set(self.options.starting_spells.value) & set(ITEM_GROUPS.get("Spells", []))
        if not self._is_bingo():
            # Vanilla physically needs Lumos+Flipendo to clear Whomping Willow,
            # so force them precollected — a vanilla seed is always playable
            # regardless of what (if anything) starting_spells lists.
            spells |= {"Lumos", "Flipendo"}
        # Bingo: no keys precollected (all 13 are AP items). Vanilla with
        # vanilla_gate_levels on: precollect every key except the 7 that gate a
        # region behind a bookcase. Vanilla with it off: precollect all 13 so
        # every region opens immediately and no bookcase spawns.
        if self._is_bingo():
            keys: set[str] = set()
        elif self.options.vanilla_gate_levels:
            keys = BINGO_KEY_NAMES - VANILLA_BLOCKED_KEY_NAMES
        else:
            keys = set(BINGO_KEY_NAMES)
        return spells | keys

    def _apply_missable_exclusions(self) -> None:
        # A missable secret lives in a one-way level: reachable only while the
        # player is passing through that level the single time. It is safe to
        # hold progression only if it is guaranteed reachable then — i.e.
        # allow_secrets_progression is on AND every item it depends on (region
        # entry AND its own requires) is precollected. Otherwise force it
        # filler-only so AP fill never gates the seed on a location the level
        # makes permanently unreachable.
        precollected = self._starter_names()
        deps_map = MISSABLE_SECRET_DEPS_BINGO if self._is_bingo() else MISSABLE_SECRET_DEPS_VANILLA
        allow_prog = bool(self.options.allow_secrets_progression)
        for name in MISSABLE_SECRETS:
            if not self._location_enabled(name):
                continue
            deps = set(deps_map.get(name, []))
            eligible = allow_prog and deps.issubset(precollected)
            if eligible:
                continue
            try:
                loc = self.multiworld.get_location(name, self.player)
            except KeyError:
                continue
            loc.progress_type = LocationProgressType.EXCLUDED

    def create_items(self) -> None:
        starters = self._starter_names()
        non_filler = [
            name for name in ITEM_NAME_TO_ID
            if name not in FILLER_NAMES and self._item_enabled(name)
        ]
        placeable_non_filler = [
            name for name in non_filler
            if name not in starters
        ]
        for name in non_filler:
            if name in starters:
                self.multiworld.push_precollected(self.create_item(name))
                continue
            self.multiworld.itempool.append(self.create_item(name))

        # delta uses the FILTERED location count, not the full id-space size,
        # so disabled categories don't bloat the pool with orphan filler.
        active_location_count = sum(
            1 for loc_name in LOCATION_NAME_TO_ID if self._location_enabled(loc_name)
        )
        delta = active_location_count - len(placeable_non_filler)
        if delta > 0:
            rng: _random.Random = self.multiworld.random if hasattr(self.multiworld, "random") else _random.Random()
            for _ in range(delta):
                name = rng.choice(FILLER_NAMES)
                self.multiworld.itempool.append(self.create_item(name))

    def set_rules(self) -> None:
        from worlds.generic.Rules import add_item_rule, add_rule, set_rule

        self._apply_missable_exclusions()

        for loc_name, rule_fn in self._location_rules().items():
            try:
                loc = self.multiworld.get_location(loc_name, self.player)
            except KeyError:
                continue
            set_rule(loc, lambda state, fn=rule_fn, player=self.player: fn(state, player))

        # Placement constraint: gold card locations cannot hold silver card
        # items. Vanilla opens the gold card room after collecting 40 silver
        # cards (=4 gold keys), so a silver card buried in a gold-room
        # location creates a circular dependency where the player can't reach
        # 40 silvers to unlock the room that contains that silver. Enforced
        # at fill time.
        #
        # Resolve item-name → location-name via the two card maps emitted to
        # locations.py / items.py (CARD_CLASS_TO_ITEM_NAME and
        # CARD_CLASS_TO_LOCATION_NAME). The earlier `f"Card_{item_name}"`
        # lookup never matched any real location (names are
        # "Gold Card Room - Card Bott", not "Card_Bott"), so the
        # try/except KeyError silently swallowed the entire constraint.
        silver_items = frozenset(ITEM_GROUPS.get("Cards (Silver)", []))
        gold_card_item_names = ITEM_GROUPS.get("Cards (Gold)", [])
        item_name_to_card_class = {v: k for k, v in CARD_CLASS_TO_ITEM_NAME.items()}
        for item_name in gold_card_item_names:
            card_class = item_name_to_card_class.get(item_name)
            if card_class is None:
                continue
            loc_name = CARD_CLASS_TO_LOCATION_NAME.get(card_class)
            if loc_name is None:
                continue
            try:
                loc = self.multiworld.get_location(loc_name, self.player)
            except KeyError:
                continue
            add_item_rule(loc, lambda item, silvers=silver_items: item.name not in silvers)
            # Only the placement constraint above is enforced here: no silver
            # item may be PLACED in a gold-card location (a fill-time rule the
            # logic grammar can't express). Gold Card Room *reachability* — the
            # 40-silver gate — lives in the GoldCardRoom region `entry` of both
            # logic_vanilla.yaml and logic_bingo.yaml as a single-quoted
            # 'Silver Card - X' AND chain.

        # Quidditch-purchase vendors (Nimbus 2001 / Quidditch Armour) cost a
        # lot of beans the player can't have collected early; gate them behind
        # owning at least 3 spells AND at least 3 bingo keys (any of them — a
        # count threshold the logic grammar can't express). ANDs onto the
        # existing rule. Only the QuidditchPurchases locations that exist this
        # seed are touched, so this is a no-op when the vendors are disabled.
        spell_names = ITEM_GROUPS.get("Spells", [])
        key_names = ITEM_GROUPS.get("Bingo Keys", [])
        for loc_name, group in LOCATION_GROUPS.items():
            if group != "QuidditchPurchases":
                continue
            try:
                loc = self.multiworld.get_location(loc_name, self.player)
            except KeyError:
                continue
            add_rule(loc, lambda state, sp=spell_names, kp=key_names, player=self.player:
                sum(state.has(s, player) for s in sp) >= 3
                and sum(state.has(k, player) for k in kp) >= 3)

        goal_locations = self._goal_location_requirements().get(DEFAULT_GOAL, [])
        goal_rule = self._goal_rules().get(DEFAULT_GOAL)
        if not goal_locations and goal_rule is None:
            # Fallback: if logic.yaml has no goal defined, use M5 placeholder
            # (collect every progression item).
            progression = list(PROGRESSION_ITEM_NAMES)
            self.multiworld.completion_condition[self.player] = (
                lambda state: all(state.has(name, self.player) for name in progression)
            )
            return

        self.multiworld.completion_condition[self.player] = (
            lambda state, locs=goal_locations, fn=goal_rule, player=self.player:
                (fn(state, player) if fn is not None else True)
                and all(state.can_reach_location(loc, player) for loc in locs)
        )
