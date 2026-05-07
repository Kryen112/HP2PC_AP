"""HP2PC_AP — Harry Potter 2: Chamber of Secrets PC randomizer for Archipelago.

M5: full item / location pool. Items + locations come from data/*.yaml via
scripts/gen_apworld.py, which writes items.py and locations.py in this
directory. Re-run the generator after every YAML edit.

Goal placeholder for M5: collect all 7 spells + 3 key items. Real "defeat
Basilisk" goal detection lands in M7.
"""

from __future__ import annotations

import random as _random
from typing import Any

from BaseClasses import CollectionState, Item, ItemClassification, Location, Region
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


PROGRESSION_ITEM_NAMES: list[str] = [
    name for name, c in ITEM_CLASSIFICATIONS.items() if c == ItemClassification.progression
]


class HP2Item(Item):
    game = "Harry Potter 2"


class HP2Location(Location):
    game = "Harry Potter 2"


class HP2WebWorld(WebWorld):
    """Web frontend metadata for archipelago.gg."""


class HP2World(World):
    """Harry Potter and the Chamber of Secrets (PC) randomizer."""

    game = "Harry Potter 2"
    web = HP2WebWorld()

    item_name_to_id = ITEM_NAME_TO_ID
    location_name_to_id = LOCATION_NAME_TO_ID
    item_name_groups = ITEM_GROUPS

    def create_item(self, name: str) -> HP2Item:
        return HP2Item(name, ITEM_CLASSIFICATIONS[name], self.item_name_to_id[name], self.player)

    def create_regions(self) -> None:
        menu = Region("Menu", self.player, self.multiworld)
        self.multiworld.regions.append(menu)

        regions_by_name: dict[str, Region] = {"Menu": menu}
        for region_name in sorted({r for r in LOCATION_REGIONS.values() if r != "TBD"} | {"TBD"}):
            r = Region(region_name, self.player, self.multiworld)
            regions_by_name[region_name] = r
            self.multiworld.regions.append(r)
            menu.connect(r)

        for loc_name, region_name in LOCATION_REGIONS.items():
            r = regions_by_name[region_name]
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
        progression = list(PROGRESSION_ITEM_NAMES)
        self.multiworld.completion_condition[self.player] = (
            lambda state: all(state.has(name, self.player) for name in progression)
        )
