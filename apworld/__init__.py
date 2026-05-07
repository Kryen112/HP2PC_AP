"""HP2PC_AP — Harry Potter 2: Chamber of Secrets PC randomizer for Archipelago.

M4 minimal world: 1 region (Hub), 1 location (TestLocation), 1 progression item
(TestVictoryItem), goal = collect TestVictoryItem. The single item lands at the
single location, so seeds are trivially solvable. This exists to prove the
end-to-end AP integration: generate seed → connect client → CHECK → server →
RECEIVED ITEM → goal complete. M5 expands to the full 111-item / 117+-location
HP2 pool driven from data/*.yaml.
"""

from __future__ import annotations

from BaseClasses import Item, ItemClassification, Location, Region
from worlds.AutoWorld import WebWorld, World


HP2_ID_BASE = 0x4D5A_0000  # arbitrary 32-bit prefix for HP2 IDs; "MZ" as a nod to the .exe

ITEM_NAME_TO_ID = {
    "TestVictoryItem": HP2_ID_BASE + 1,
}

LOCATION_NAME_TO_ID = {
    "TestLocation": HP2_ID_BASE + 1,
}


class HP2Item(Item):
    game = "Harry Potter 2"


class HP2Location(Location):
    game = "Harry Potter 2"


class HP2WebWorld(WebWorld):
    """Web frontend metadata for archipelago.gg."""


class HP2World(World):
    """Harry Potter and the Chamber of Secrets (PC) randomizer.

    See README and docs/DESIGN.md in the HP2PC_AP repo for full design context.
    """

    game = "Harry Potter 2"
    web = HP2WebWorld()

    item_name_to_id = ITEM_NAME_TO_ID
    location_name_to_id = LOCATION_NAME_TO_ID

    def create_item(self, name: str) -> HP2Item:
        return HP2Item(name, ItemClassification.progression, self.item_name_to_id[name], self.player)

    def create_regions(self) -> None:
        menu = Region("Menu", self.player, self.multiworld)
        hub = Region("Hub", self.player, self.multiworld)

        loc = HP2Location(self.player, "TestLocation", self.location_name_to_id["TestLocation"], hub)
        hub.locations.append(loc)

        menu.connect(hub)

        self.multiworld.regions.append(menu)
        self.multiworld.regions.append(hub)

    def create_items(self) -> None:
        self.multiworld.itempool.append(self.create_item("TestVictoryItem"))

    def set_rules(self) -> None:
        self.multiworld.completion_condition[self.player] = (
            lambda state: state.has("TestVictoryItem", self.player)
        )
