"""The client translates each received Progressive Level Key copy into the
next concrete story-chain key: the GRANT payload the mod applies and the
RESYNC_BLOCKERKEYS ledger only ever name real keys (the .uc protocol is
frozen). These tests drive the real context methods over a stubbed
received-items dict to pin the copy-order mapping, the ledger expansion, the
GRANT forwarding branch, and /hint's count-wise entry consumption."""

import asyncio
import unittest
from collections import namedtuple

from ..Client import GAME_NAME, HP2CommandProcessor, HP2Context
from ..items import (ITEM_NAME_TO_ID, PROGRESSIVE_LEVEL_KEY_NAME,
                     PROGRESSIVE_LEVEL_KEY_ORDER)

_Item = namedtuple("_Item", ["item"])
_NetworkItem = namedtuple("_NetworkItem", ["item", "location", "player", "flags"])
_ID_TO_NAME = {item_id: name for name, item_id in ITEM_NAME_TO_ID.items()}


class _Names:
    @staticmethod
    def lookup_in_game(item_id: int, game: str = GAME_NAME) -> str:
        return _ID_TO_NAME.get(item_id, "")


class TestProgressiveKeyTranslation(unittest.TestCase):
    def setUp(self) -> None:
        # Bypass CommonContext.__init__ (needs a server address / event loop);
        # the methods under test only read received_by_index and item_names.
        self.ctx = HP2Context.__new__(HP2Context)
        self.ctx.item_names = _Names()
        self.ctx.received_by_index = {}

    def receive(self, idx: int, name: str) -> None:
        self.ctx.received_by_index[idx] = _Item(ITEM_NAME_TO_ID[name])

    def test_copies_map_to_chain_in_receive_order(self) -> None:
        # Copies interleaved with unrelated items at arbitrary indices: the
        # Nth copy by index order maps to the Nth chain key.
        self.receive(0, "Alohomora")
        self.receive(1, PROGRESSIVE_LEVEL_KEY_NAME)
        self.receive(2, "Duelling Key")
        self.receive(5, PROGRESSIVE_LEVEL_KEY_NAME)
        self.receive(9, PROGRESSIVE_LEVEL_KEY_NAME)
        self.assertEqual(self.ctx._progressive_key_concrete_name(1), "Bicorn Level Key")
        self.assertEqual(self.ctx._progressive_key_concrete_name(5), "Boomslang Level Key")
        self.assertEqual(self.ctx._progressive_key_concrete_name(9), "Goyle Level Key")

    def test_full_chain_and_overflow_clamp(self) -> None:
        # Six copies: the first five walk the chain, the sixth (a cheat-sent
        # extra) repeats the final key rather than indexing past the list.
        for idx in range(6):
            self.receive(idx, PROGRESSIVE_LEVEL_KEY_NAME)
        for idx, expected in enumerate(PROGRESSIVE_LEVEL_KEY_ORDER):
            self.assertEqual(self.ctx._progressive_key_concrete_name(idx), expected)
        self.assertEqual(self.ctx._progressive_key_concrete_name(5),
                         PROGRESSIVE_LEVEL_KEY_ORDER[-1])

    def test_mapping_is_stable_regardless_of_lookup_order(self) -> None:
        # The mapping keys on index position, not lookup sequence, so a
        # reconnect replaying the same ReceivedItems yields the same keys.
        self.receive(3, PROGRESSIVE_LEVEL_KEY_NAME)
        self.receive(7, PROGRESSIVE_LEVEL_KEY_NAME)
        second_then_first = (self.ctx._progressive_key_concrete_name(7),
                             self.ctx._progressive_key_concrete_name(3))
        self.assertEqual(second_then_first, ("Boomslang Level Key", "Bicorn Level Key"))

    def test_blocker_key_ledger_expands_copies(self) -> None:
        # Three copies plus a named standalone key: the RESYNC ledger carries
        # the first three chain keys and the named key, nothing deeper.
        self.receive(0, PROGRESSIVE_LEVEL_KEY_NAME)
        self.receive(1, "Duelling Key")
        self.receive(2, PROGRESSIVE_LEVEL_KEY_NAME)
        self.receive(3, PROGRESSIVE_LEVEL_KEY_NAME)
        names = self.ctx.granted_blocker_key_names
        self.assertEqual(
            names,
            {"Bicorn Level Key", "Boomslang Level Key", "Goyle Level Key",
             "Duelling Key"})

    def test_ledger_without_copies_is_unchanged(self) -> None:
        self.receive(0, "Quidditch Key")
        self.assertEqual(self.ctx.granted_blocker_key_names, {"Quidditch Key"})


class TestProgressiveKeyForwarding(unittest.TestCase):
    def setUp(self) -> None:
        self.ctx = HP2Context.__new__(HP2Context)
        self.ctx.item_names = _Names()
        self.ctx.received_by_index = {}
        self.ctx.consumed_indices = set()
        self.ctx.sent_this_session = set()
        self.ctx.player_names = {1: "Harry"}
        self.ctx.slot = 1
        self.sent_lines: list[str] = []
        self.ctx._send_to_game = self.sent_lines.append
        self.ctx._maybe_broadcast_traplink = lambda item_name: None

    def receive(self, idx: int, name: str, flags: int = 1) -> None:
        self.ctx.received_by_index[idx] = _NetworkItem(
            ITEM_NAME_TO_ID[name], 0, 1, flags)

    def test_grant_payload_is_the_concrete_key(self) -> None:
        # The second copy forwards as the second chain key; the toast segment
        # names the AP item plus the level it opened, coloured progression.
        self.receive(0, PROGRESSIVE_LEVEL_KEY_NAME)
        self.receive(1, PROGRESSIVE_LEVEL_KEY_NAME)
        self.ctx._forward_one(1, self.ctx.received_by_index[1])
        self.assertEqual(len(self.sent_lines), 1)
        payload, segrecord = self.sent_lines[0].split("\x1f", 1)
        self.assertEqual(payload, "GRANT 1 Boomslang Level Key")
        self.assertIn("gProgressive Level Key (Boomslang Level)", segrecord)

    def test_cheat_sent_copy_recovers_progression_colour(self) -> None:
        # flags=0 (server /send builds no flags): the decorated toast name
        # defeats the own-name role lookup, so the branch recovers the
        # progression flag from the plain item name.
        self.receive(0, PROGRESSIVE_LEVEL_KEY_NAME, flags=0)
        self.ctx._forward_one(0, self.ctx.received_by_index[0])
        _, segrecord = self.sent_lines[0].split("\x1f", 1)
        self.assertIn("gProgressive Level Key (Bicorn Level)", segrecord)

    def test_named_key_payload_is_untouched(self) -> None:
        self.receive(0, "Duelling Key")
        self.ctx._forward_one(0, self.ctx.received_by_index[0])
        payload, _ = self.sent_lines[0].split("\x1f", 1)
        self.assertEqual(payload, "GRANT 0 Duelling Key")


class TestHintCountsCopies(unittest.TestCase):
    def setUp(self) -> None:
        self.ctx = HP2Context.__new__(HP2Context)
        self.ctx.item_names = _Names()
        self.ctx.received_by_index = {}
        self.ctx.server = object()
        self.ctx.slot = 1
        self.hints_sent: list[str] = []

        async def record_msg(msg: dict, label: str) -> None:
            self.hints_sent.append(msg["text"])

        self.ctx._send_or_queue_ap_msg = record_msg
        self.processor = HP2CommandProcessor.__new__(HP2CommandProcessor)
        self.processor.ctx = self.ctx
        self.outputs: list[str] = []
        self.processor.output = self.outputs.append

    def receive(self, idx: int, name: str) -> None:
        self.ctx.received_by_index[idx] = _Item(ITEM_NAME_TO_ID[name])

    def hint_key(self) -> None:
        # _cmd_hint schedules the !hint send with asyncio.create_task, so it
        # must run inside a live event loop.
        async def run() -> None:
            self.processor._cmd_hint("key")

        asyncio.run(run())

    def test_each_copy_consumes_one_entry(self) -> None:
        # Two received copies consume the first two progressive entries, so
        # the next in-logic key is the named key between them.
        self.ctx.hint_order = {"key": [
            PROGRESSIVE_LEVEL_KEY_NAME, PROGRESSIVE_LEVEL_KEY_NAME,
            "Duelling Key", PROGRESSIVE_LEVEL_KEY_NAME,
        ]}
        self.receive(0, PROGRESSIVE_LEVEL_KEY_NAME)
        self.receive(1, PROGRESSIVE_LEVEL_KEY_NAME)
        self.hint_key()
        self.assertEqual(self.hints_sent, ["!hint Duelling Key"])

    def test_third_copy_still_hintable(self) -> None:
        self.ctx.hint_order = {"key": [
            PROGRESSIVE_LEVEL_KEY_NAME, PROGRESSIVE_LEVEL_KEY_NAME,
            "Duelling Key", PROGRESSIVE_LEVEL_KEY_NAME,
        ]}
        self.receive(0, PROGRESSIVE_LEVEL_KEY_NAME)
        self.receive(1, PROGRESSIVE_LEVEL_KEY_NAME)
        self.receive(2, "Duelling Key")
        self.hint_key()
        self.assertEqual(self.hints_sent, [f"!hint {PROGRESSIVE_LEVEL_KEY_NAME}"])

    def test_all_copies_received_reports_complete(self) -> None:
        self.ctx.hint_order = {"key": [PROGRESSIVE_LEVEL_KEY_NAME] * 2}
        self.receive(0, PROGRESSIVE_LEVEL_KEY_NAME)
        self.receive(1, PROGRESSIVE_LEVEL_KEY_NAME)
        self.hint_key()
        self.assertEqual(self.hints_sent, [])
        self.assertTrue(any("every key" in line for line in self.outputs))


if __name__ == "__main__":
    unittest.main()
