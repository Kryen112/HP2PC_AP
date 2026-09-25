"""The Always Goyle in Slytherin Common Room option is open castle only. The
slot_data flag the mod keys on must read off for every vanilla seed, and the
client must mirror it to the game as its IPC line."""

import unittest

from ..Client import HP2Context
from .bases import HP2TestBase

FLAG = "always_goyle_in_slytherin_common_room"


class TestDisguiseDefaultsOnInOpenCastle(HP2TestBase):
    options = {"game_mode": "open_castle"}
    run_default_tests = False

    def test_slot_data_flag_is_on(self) -> None:
        self.assertIs(self.world.fill_slot_data()[FLAG], True)


class TestDisguiseOffInOpenCastle(HP2TestBase):
    options = {"game_mode": "open_castle", FLAG: False}
    run_default_tests = False

    def test_slot_data_flag_is_off(self) -> None:
        self.assertIs(self.world.fill_slot_data()[FLAG], False)


class TestDisguiseNeverOnInVanilla(HP2TestBase):
    options = {"game_mode": "vanilla", FLAG: True}
    run_default_tests = False

    def test_slot_data_flag_is_off(self) -> None:
        self.assertIs(self.world.fill_slot_data()[FLAG], False)


class TestDisguiseClientMirror(unittest.TestCase):
    def setUp(self) -> None:
        self.ctx = HP2Context.__new__(HP2Context)
        self.sent_lines: list = []
        self.ctx._send_to_game = self.sent_lines.append

    def _apply(self, slot_data: dict) -> bool:
        return self.ctx._apply_bool_slot_flag(
            slot_data, FLAG, FLAG, "ALWAYS_GOYLE_IN_SLYTHERIN_COMMON_ROOM",
            "Always Goyle in Slytherin Common Room")

    def test_on_sends_one(self) -> None:
        self.assertTrue(self._apply({FLAG: True}))
        self.assertEqual(self.sent_lines, ["ALWAYS_GOYLE_IN_SLYTHERIN_COMMON_ROOM 1"])
        self.assertTrue(self.ctx.always_goyle_in_slytherin_common_room)

    def test_missing_key_sends_zero(self) -> None:
        self.assertFalse(self._apply({}))
        self.assertEqual(self.sent_lines, ["ALWAYS_GOYLE_IN_SLYTHERIN_COMMON_ROOM 0"])
