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
                         Region)
from Options import (Choice, DefaultOnToggle, PerGameCommonOptions,
                     StartInventoryPool, Toggle)
from worlds.AutoWorld import WebWorld, World
from worlds.LauncherComponents import Component, Type, components
from worlds.LauncherComponents import launch as launch_component

from .items import BASE_ID as ITEM_BASE_ID
from .items import (CARD_CLASS_TO_ITEM_NAME, FILLER_NAMES,
                    ITEM_CLASSIFICATIONS, ITEM_GROUPS, ITEM_NAME_TO_ID)
from .locations import BASE_ID as LOCATION_BASE_ID
from .locations import (CARD_CLASS_TO_LOCATION_NAME,
                        CARD_GAME_ID_TO_LOCATION_NAME, LOCATION_GROUPS,
                        LOCATION_NAME_TO_ID, LOCATION_REGIONS)
from .regions import REGION_ENTRY_RULES, REGION_NAMES, START_REGION
from .rules import GOAL_LOCATION_REQUIREMENTS, GOAL_RULES, LOCATION_RULES

PROGRESSION_ITEM_NAMES: list[str] = [
    name for name, c in ITEM_CLASSIFICATIONS.items() if c == ItemClassification.progression
]

DEFAULT_GOAL = "basilisk"
STARTER_ITEM_NAMES: set[str] = {"Lumos", "Flipendo", "Alohomora"}


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

    `vanilla` (default): retail HP2 + M212 patch. Lumos / Flipendo / Alohomora
    are precollected starters; the other 4 spells are in the AP pool.

    `bingo`: the bingo-distribution maps (open castle, every door unlocked).
    NO spells are precollected, all 7 land as AP items.
    """
    display_name = "Game Mode"
    option_vanilla = 0
    option_bingo = 1
    default = 0


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
    # Locations not listed here (currently only the Classrooms group) are
    # never filtered — spells need somewhere to live.
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

    def _location_enabled(self, loc_name: str) -> bool:
        group = LOCATION_GROUPS.get(loc_name)
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
            rule_fn = REGION_ENTRY_RULES.get(region_name)
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
        # Bingo maps have base cutscenes (incl. the Privet Drive / intro grants
        # of Lumos / Flipendo / Alohomora) removed, so no spell is owned at
        # spawn — every spell must come from AP. In vanilla, the 3 cutscene
        # starters stay precollected so AP logic treats Harry as owning them.
        if self.options.game_mode.current_key == "bingo":
            return set()
        return STARTER_ITEM_NAMES

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

        for loc_name, rule_fn in LOCATION_RULES.items():
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
        silver_items_list = tuple(ITEM_GROUPS.get("Cards (Silver)", []))
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
            # Reachability gate: the Gold Card Room only opens after the
            # player has 4 Silver keys, earned at the 1-per-10-Silvers rate,
            # i.e. all 40 Silver cards. The rule grammar can't express group
            # counts, so the closure ANDs an explicit "have every Silver item
            # in the pool" check onto each Gold location. Composes with the
            # GoldCardRoom region entry (full-spell prereq) via add_rule.
            add_rule(loc, lambda state, silvers=silver_items_list, player=self.player:
                all(state.has(s, player) for s in silvers))

        goal_locations = GOAL_LOCATION_REQUIREMENTS.get(DEFAULT_GOAL, [])
        goal_rule = GOAL_RULES.get(DEFAULT_GOAL)
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
