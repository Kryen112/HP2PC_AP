"""fill_slot_data (generate step 19.5) is what the client reads on connect, so
it must be JSON-serializable and report the game mode the world generated for."""

import json

from .bases import HP2TestBase


class TestVanillaSlotData(HP2TestBase):
    options = {"game_mode": "vanilla"}
    run_default_tests = False

    def test_slot_data_is_json_serializable(self) -> None:
        json.dumps(self.world.fill_slot_data())

    def test_slot_data_reports_game_mode(self) -> None:
        self.assertEqual(self.world.fill_slot_data()["game_mode"], "vanilla")


class TestOpenCastleSlotData(HP2TestBase):
    options = {"game_mode": "open_castle"}
    run_default_tests = False

    def test_slot_data_is_json_serializable(self) -> None:
        json.dumps(self.world.fill_slot_data())

    def test_slot_data_reports_game_mode(self) -> None:
        self.assertEqual(self.world.fill_slot_data()["game_mode"], "open_castle")


class TestGhostPlayersSlotData(HP2TestBase):
    """The client learns the ghost toggle only through slot_data, and it is on
    unless the player turns it off."""
    options = {"game_mode": "open_castle"}
    run_default_tests = False

    def test_ghost_players_defaults_on(self) -> None:
        self.assertIs(self.world.fill_slot_data()["ghost_players"], True)


class TestGhostPlayersOffSlotData(HP2TestBase):
    options = {"game_mode": "open_castle", "ghost_players": False}
    run_default_tests = False

    def test_ghost_players_off_reaches_slot_data(self) -> None:
        self.assertIs(self.world.fill_slot_data()["ghost_players"], False)
