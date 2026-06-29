from test.bases import WorldTestBase

from BaseClasses import CollectionState

from .. import HP2World


class HP2TestBase(WorldTestBase):
    game = "Harry Potter 2 PC"
    world: HP2World

    def state_with(self, names: list[str]) -> CollectionState:
        """A CollectionState holding exactly the named items (no sweep)."""
        state = CollectionState(self.multiworld)
        for name in names:
            state.collect(self.world.create_item(name), prevent_sweep=True)
        return state

    def state_all_but(self, names: list[str]) -> CollectionState:
        """A CollectionState with every item collected except the named ones."""
        state = CollectionState(self.multiworld)
        self.collect_all_but(names, state)
        return state

    def assert_location_exists(self, name: str) -> None:
        """Fail with a clear message if the location was not created."""
        try:
            self.world.get_location(name)
        except KeyError:
            self.fail(f"expected location {name!r} to exist")
