"""HP2PC_AP — Harry Potter 2: Chamber of Secrets PC randomizer for Archipelago.

M5: full item / location pool. Items + locations come from data/*.yaml via
scripts/gen_apworld.py, which writes items.py and locations.py in this
directory. Re-run the generator after every YAML edit.

Goal placeholder for M5: collect all 7 spells + 3 key items. Real "defeat
Basilisk" goal detection lands in M7 — triggered by Harry entering the
Great Hall post-kill (the speedrun endpoint), not the Basilisk death itself.
"""

from __future__ import annotations

import random as _random
from dataclasses import dataclass
from typing import Any

from BaseClasses import CollectionState, Item, ItemClassification, Location, Region
from Options import PerGameCommonOptions, StartInventoryPool
from worlds.AutoWorld import WebWorld, World

from .items import (
    BASE_ID as ITEM_BASE_ID,
    CARD_CLASS_TO_ITEM_NAME,
    FILLER_NAMES,
    ITEM_CLASSIFICATIONS,
    ITEM_GROUPS,
    ITEM_NAME_TO_ID,
)
from .locations import (
    BASE_ID as LOCATION_BASE_ID,
    CARD_CLASS_TO_LOCATION_NAME,
    CARD_GAME_ID_TO_LOCATION_NAME,
    LOCATION_GROUPS,
    LOCATION_NAME_TO_ID,
    LOCATION_REGIONS,
)
from .regions import (
    REGION_ENTRY_RULES,
    REGION_NAMES,
    START_REGION,
)
from .rules import (
    GOAL_REQUIREMENTS,
    LOCATION_RULES,
)


PROGRESSION_ITEM_NAMES: list[str] = [
    name for name, c in ITEM_CLASSIFICATIONS.items() if c == ItemClassification.progression
]

DEFAULT_GOAL = "basilisk"


class HP2Item(Item):
    game = "Harry Potter 2"


class HP2Location(Location):
    game = "Harry Potter 2"


class HP2WebWorld(WebWorld):
    """Web frontend metadata for archipelago.gg."""


@dataclass
class HP2Options(PerGameCommonOptions):
    # PerGameCommonOptions includes start_inventory (just-add) but NOT
    # StartInventoryPool (add-and-remove-from-pool). Adding it explicitly
    # so HP2_Test.yaml can pre-load Lumos/Flipendo/Alohomora without
    # leaving duplicates in the world.
    start_inventory_from_pool: StartInventoryPool


class HP2World(World):
    """Harry Potter and the Chamber of Secrets (PC) randomizer."""

    game = "Harry Potter 2"
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
            r = regions_by_name.get(region_name) or regions_by_name["TBD"]
            loc_id = LOCATION_NAME_TO_ID[loc_name]
            r.locations.append(HP2Location(self.player, loc_name, loc_id, r))

    def create_items(self) -> None:
        non_filler = [
            name for name in ITEM_NAME_TO_ID
            if name not in FILLER_NAMES
        ]
        for name in non_filler:
            self.multiworld.itempool.append(self.create_item(name))

        delta = len(LOCATION_NAME_TO_ID) - len(non_filler)
        if delta > 0:
            rng: _random.Random = self.multiworld.random if hasattr(self.multiworld, "random") else _random.Random()
            for _ in range(delta):
                name = rng.choice(FILLER_NAMES)
                self.multiworld.itempool.append(self.create_item(name))

    def set_rules(self) -> None:
        from worlds.generic.Rules import set_rule

        for loc_name, rule_fn in LOCATION_RULES.items():
            try:
                loc = self.multiworld.get_location(loc_name, self.player)
            except KeyError:
                continue
            set_rule(loc, lambda state, fn=rule_fn, player=self.player: fn(state, player))

        goal_locations = GOAL_REQUIREMENTS.get(DEFAULT_GOAL, [])
        if not goal_locations:
            # Fallback: if logic.yaml has no goal defined, use M5 placeholder
            # (collect every progression item).
            progression = list(PROGRESSION_ITEM_NAMES)
            self.multiworld.completion_condition[self.player] = (
                lambda state: all(state.has(name, self.player) for name in progression)
            )
            return

        self.multiworld.completion_condition[self.player] = (
            lambda state, locs=goal_locations, player=self.player:
                all(state.can_reach_location(loc, player) for loc in locs)
        )
