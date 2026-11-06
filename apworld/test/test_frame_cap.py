"""The frame rate cap: four bytes in the install's Engine.dll make the engine
hold the game at 60 frames per second, with a pristine backup, and only an
engine with the expected bytes is changed. The engines here are synthetic
byte strings, never game data."""

import asyncio
import os
import shutil
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

from .. import Client, HP2Settings, frame_cap
from ..Client import GAME_NONE, GAME_RUNNING, HP2Context
from ..frame_cap import CAP_OFFSET, ORIGINAL, PATCHED
from ..ue1_package import PatchError


def _engine(instruction: bytes = ORIGINAL) -> bytes:
    return bytes(range(256)) * (CAP_OFFSET // 256) + bytes(CAP_OFFSET % 256) + instruction + b"\x90" * 64


class _InstallCase(unittest.TestCase):
    def setUp(self) -> None:
        self.install = tempfile.mkdtemp(prefix="hp2_frame_cap_")
        self.addCleanup(shutil.rmtree, self.install, True)
        os.mkdir(os.path.join(self.install, "system"))
        self.path = frame_cap.engine_path(self.install)

    def write(self, data: bytes) -> None:
        with open(self.path, "wb") as f:
            f.write(data)

    def read(self, suffix: str = "") -> bytes:
        with open(self.path + suffix, "rb") as f:
            return f.read()


class TestFrameCap(_InstallCase):
    def test_cap_changes_only_the_instruction_and_keeps_a_backup(self) -> None:
        original = _engine()
        self.write(original)
        self.assertEqual(frame_cap.apply_cap(self.install), "patched")
        capped = self.read()
        self.assertEqual(capped, _engine(PATCHED))
        changed = [index for index, (a, b) in enumerate(zip(capped, original)) if a != b]
        self.assertTrue(changed and min(changed) >= CAP_OFFSET and max(changed) < CAP_OFFSET + 4)
        self.assertEqual(self.read(".orig"), original)

    def test_cap_twice_changes_nothing(self) -> None:
        self.write(_engine())
        frame_cap.apply_cap(self.install)
        self.assertEqual(frame_cap.apply_cap(self.install), "unchanged")
        self.assertEqual(self.read(), _engine(PATCHED))

    def test_remove_puts_the_original_back(self) -> None:
        self.write(_engine())
        frame_cap.apply_cap(self.install)
        self.assertEqual(frame_cap.remove_cap(self.install), "restored")
        self.assertEqual(self.read(), _engine())
        self.assertEqual(frame_cap.remove_cap(self.install), "unchanged")

    def test_engine_capped_by_hand_is_left_as_it_is(self) -> None:
        self.write(_engine(PATCHED))
        self.assertEqual(frame_cap.apply_cap(self.install), "unchanged")
        self.assertFalse(os.path.exists(self.path + ".orig"))
        self.assertEqual(frame_cap.remove_cap(self.install), "no-backup")

    def test_other_engine_is_left_alone(self) -> None:
        other = _engine(b"\x90" * len(ORIGINAL))
        self.write(other)
        self.assertEqual(frame_cap.apply_cap(self.install), "unknown")
        self.assertEqual(self.read(), other)
        self.assertFalse(os.path.exists(self.path + ".orig"))

    def test_engine_swapped_in_after_the_backup_is_kept(self) -> None:
        self.write(_engine())
        frame_cap.apply_cap(self.install)
        self.write(b"replaced")
        self.assertEqual(frame_cap.apply_cap(self.install), "unknown")
        self.assertEqual(self.read(), b"replaced")

    def test_original_put_back_by_hand_is_capped_again(self) -> None:
        self.write(_engine())
        frame_cap.apply_cap(self.install)
        self.write(_engine())
        self.assertEqual(frame_cap.apply_cap(self.install), "patched")
        self.assertEqual(self.read(), _engine(PATCHED))

    def test_swapped_engine_is_kept_when_the_cap_is_off_too(self) -> None:
        self.write(_engine())
        frame_cap.apply_cap(self.install)
        self.write(b"replaced")
        self.assertEqual(frame_cap.remove_cap(self.install), "unknown")
        self.assertEqual(self.read(), b"replaced")

    def test_change_pending_matches_what_the_next_start_does(self) -> None:
        self.assertFalse(frame_cap.change_pending(self.install, True))
        self.write(_engine())
        self.assertTrue(frame_cap.change_pending(self.install, True))
        self.assertFalse(frame_cap.change_pending(self.install, False))
        frame_cap.apply_cap(self.install)
        self.assertFalse(frame_cap.change_pending(self.install, True))
        self.assertTrue(frame_cap.change_pending(self.install, False))
        self.write(b"replaced")
        self.assertFalse(frame_cap.change_pending(self.install, True))
        self.assertFalse(frame_cap.change_pending(self.install, False))

    def test_hand_capped_engine_has_nothing_pending_when_off(self) -> None:
        self.write(_engine(PATCHED))
        self.assertFalse(frame_cap.change_pending(self.install, False))

    def test_missing_engine(self) -> None:
        self.assertEqual(frame_cap.apply_cap(self.install), "no-file")
        self.assertEqual(frame_cap.remove_cap(self.install), "no-backup")


class TestClientFrameCap(_InstallCase):
    def run_client(self, enabled: bool, state: str = GAME_NONE) -> None:
        context = mock.Mock()
        context._game_state = mock.AsyncMock(return_value=state)
        with mock.patch.object(Client, "_frame_cap_enabled", return_value=enabled):
            asyncio.run(HP2Context._apply_frame_cap(context, self.install))

    def test_setting_on_caps_and_off_restores(self) -> None:
        self.write(_engine())
        with mock.patch.object(frame_cap, "apply_cap", return_value="patched") as apply, \
                mock.patch.object(frame_cap, "remove_cap", return_value="restored") as remove:
            with self.assertNoLogs("Client", level="INFO"), \
                    self.assertLogs("HP2Client", level="INFO") as logs:
                self.run_client(True)
                self.run_client(False)
        apply.assert_called_once_with(self.install)
        remove.assert_called_once_with(self.install)
        self.assertIn("60 frames per second", logs.output[0])
        self.assertIn("restored the original engine", logs.output[1])

    def test_running_game_is_left_alone_and_the_change_announced(self) -> None:
        self.write(_engine())
        with mock.patch.object(frame_cap, "apply_cap") as apply:
            with self.assertLogs("Client", level="INFO") as logs:
                self.run_client(True, GAME_RUNNING)
        apply.assert_not_called()
        self.assertIn("turns on the next time the game starts", logs.output[0])

    def test_hand_capped_engine_turned_off_is_explained(self) -> None:
        self.write(_engine(PATCHED))
        with self.assertLogs("Client", level="WARNING") as logs:
            self.run_client(False)
        self.assertIn("no Engine.dll.orig to put back", logs.output[0])
        self.assertEqual(self.read(), _engine(PATCHED))

    def test_unreadable_engine_with_a_running_game_does_not_raise(self) -> None:
        self.write(_engine())
        with mock.patch.object(frame_cap, "change_pending", side_effect=PermissionError("locked")):
            self.run_client(True, GAME_RUNNING)

    def test_running_game_already_as_wanted_says_nothing(self) -> None:
        self.write(_engine(PATCHED))
        with mock.patch.object(Client.ui_logger, "info") as info:
            self.run_client(True, GAME_RUNNING)
        info.assert_not_called()

    def test_install_without_an_engine_is_left_alone(self) -> None:
        with mock.patch.object(frame_cap, "apply_cap") as apply:
            self.run_client(True)
        apply.assert_not_called()

    def test_other_engine_is_reported(self) -> None:
        self.write(_engine())
        with mock.patch.object(frame_cap, "apply_cap", return_value="unknown"):
            with self.assertLogs("Client", level="WARNING") as logs:
                self.run_client(True)
        self.assertIn("not the one the frame rate cap is for", logs.output[0])

    def test_write_error_is_reported_not_raised(self) -> None:
        self.write(_engine())
        with mock.patch.object(frame_cap, "apply_cap", side_effect=PatchError("denied")):
            with self.assertLogs("Client", level="ERROR") as logs:
                self.run_client(True)
        self.assertIn("denied", logs.output[0])

    def test_unexpected_error_is_reported_not_raised(self) -> None:
        self.write(_engine())
        with mock.patch.object(frame_cap, "apply_cap", side_effect=ValueError("broken")):
            with self.assertLogs("Client", level="ERROR") as logs:
                self.run_client(True)
        self.assertIn("frame rate cap crashed", logs.output[0])


class TestDisplaySettingDefaults(unittest.TestCase):
    def test_new_settings_are_on_by_default(self) -> None:
        group = HP2Settings()
        self.assertTrue(group.frame_rate_cap)
        self.assertTrue(group.widescreen_view)
        self.assertTrue(group.borderless_window)

    def test_unreadable_settings_keep_the_game_right(self) -> None:
        broken = SimpleNamespace()
        with mock.patch.object(Client, "HP2World", SimpleNamespace(settings=broken)):
            self.assertTrue(Client._frame_cap_enabled())
            self.assertTrue(Client._widescreen_enabled())
            self.assertFalse(Client._borderless_enabled())


class TestWidescreenLine(unittest.TestCase):
    def hello(self, enabled: bool) -> "list[str]":
        context = mock.Mock(seed_mode=None, open_castle_goalcfg=None, tradersanity_cfg=None,
                            tradersanity_prices_csv=None, appearance_csv=None, connected_address=None,
                            checked_csv=None, ledger_loaded=False, beanroom_loaded=False)
        sent = []
        context._send_to_game = sent.append
        with mock.patch.object(Client, "_widescreen_enabled", return_value=enabled):
            asyncio.run(HP2Context._on_hello(context, "HELLO"))
        return sent

    def test_every_hello_carries_the_setting(self) -> None:
        self.assertIn("WIDESCREEN 1", self.hello(True))
        self.assertIn("WIDESCREEN 0", self.hello(False))
