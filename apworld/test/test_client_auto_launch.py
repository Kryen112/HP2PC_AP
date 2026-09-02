"""Auto-launch opens Game.exe on a connection the player asked for (the Connect
button, /connect, the startup connect) and never on the framework's automatic
retry after a dropped socket. Whether a game is already up is read from the
bridge and the process list, not from a launch flag: a game closed at its
launcher page never bridges, so nothing tied to the bridge can tell it apart
from one still running. These tests drive the real launch step with the file
work, the process probe and the spawn stubbed, so no server, install or
process is needed."""

import asyncio
import unittest
from unittest import mock

from CommonClient import CommonContext

from .. import Client
from ..Client import HP2Context


class _Ctx(HP2Context):
    """Context with only the launch-step state, recording what the real methods
    would have done instead of touching files, processes or sockets."""

    def __init__(self, game_up: bool = False, safe: bool = True) -> None:
        self._player_connect_pending = False
        self.game_writer = None
        self.game_up = game_up
        self.safe = safe
        self.launched: list = []

    async def _apply_audio_randomizers(self, sd: dict):
        return self.safe, "install"

    async def _ensure_mod_current(self, install):
        return install

    async def _game_is_up(self) -> bool:
        return self.game_up

    async def _auto_launch(self, install_hint) -> None:
        self.launched.append(install_hint)

    async def _resolve_launch_folder(self):
        return "install"


class _InstallerCtx(_Ctx):
    """The launch-step stub with the real mod-current check restored, so the
    installer path runs for real down to the patched installer module."""

    _ensure_mod_current = HP2Context._ensure_mod_current


def _run(coro):
    return asyncio.run(coro)


@mock.patch.object(Client, "_auto_install_enabled", return_value=False)
@mock.patch.object(Client, "_auto_launch_enabled", return_value=True)
class TestAutoLaunchDecision(unittest.TestCase):
    def test_player_connect_launches_when_no_game_is_up(self, *_) -> None:
        ctx = _Ctx()
        ctx._player_connect_pending = True
        _run(ctx._connect_audio_then_launch({}))
        self.assertEqual(ctx.launched, ["install"])
        self.assertFalse(ctx._player_connect_pending)

    def test_automatic_reconnect_never_launches(self, *_) -> None:
        ctx = _Ctx()
        _run(ctx._connect_audio_then_launch({}))
        self.assertEqual(ctx.launched, [])

    def test_running_game_is_not_duplicated_and_says_so(self, *_) -> None:
        ctx = _Ctx(game_up=True)
        ctx._player_connect_pending = True
        with self.assertLogs("Client", level="INFO") as captured:
            _run(ctx._connect_audio_then_launch({}))
        self.assertEqual(ctx.launched, [])
        self.assertTrue(any("/play" in line for line in captured.output))
        self.assertFalse(ctx._player_connect_pending)

    def test_unsafe_install_warns_instead_of_launching(self, *_) -> None:
        ctx = _Ctx(safe=False)
        ctx._player_connect_pending = True
        with self.assertLogs("Client", level="WARNING"):
            _run(ctx._connect_audio_then_launch({}))
        self.assertEqual(ctx.launched, [])


class TestAutoLaunchDisabled(unittest.TestCase):
    @mock.patch.object(Client, "_auto_install_enabled", return_value=False)
    @mock.patch.object(Client, "_auto_launch_enabled", return_value=False)
    def test_setting_off_launches_nothing_and_still_consumes_the_arm(self, *_) -> None:
        ctx = _Ctx()
        ctx._player_connect_pending = True
        _run(ctx._connect_audio_then_launch({}))
        self.assertEqual(ctx.launched, [])
        self.assertFalse(ctx._player_connect_pending)


class TestConnectArmsTheLaunch(unittest.TestCase):
    def test_connect_arms_then_defers_to_the_framework(self) -> None:
        ctx = _Ctx()
        with mock.patch.object(CommonContext, "connect", new=mock.AsyncMock()) as base:
            _run(ctx.connect("host:38281"))
        self.assertTrue(ctx._player_connect_pending)
        base.assert_awaited_once_with("host:38281")


class TestInstallerRefusesWhileGameIsUp(unittest.TestCase):
    """The installer reads the same up-check, so a game parked at its launcher
    page (a process, not yet bridged) blocks a deploy the way a bridged one does.
    Both installer entry points are driven, so a dropped await on the up-check
    (a bare coroutine reads as up) fails here rather than in a player's client."""

    def test_stale_mod_is_left_alone_while_game_is_up(self) -> None:
        ctx = _InstallerCtx(game_up=True)
        with mock.patch.object(Client.installer, "mod_is_current", return_value=False), \
                mock.patch.object(Client.installer, "deploy", side_effect=AssertionError):
            with self.assertLogs("Client", level="WARNING") as captured:
                self.assertEqual(_run(ctx._ensure_mod_current("install")), "install")
        self.assertTrue(any("type /installmod" in line for line in captured.output))

    def test_stale_mod_is_deployed_when_no_game_is_up(self) -> None:
        ctx = _InstallerCtx(game_up=False)
        with mock.patch.object(Client.installer, "mod_is_current", return_value=False), \
                mock.patch.object(Client.installer, "deploy", return_value=[]) as deploy:
            with self.assertLogs("Client", level="INFO"):
                self.assertEqual(_run(ctx._ensure_mod_current("install")), "install")
        deploy.assert_called_once_with("install")

    def test_install_mod_warns_and_skips_deploy(self) -> None:
        ctx = _Ctx(game_up=True)
        with mock.patch.object(Client.installer, "deploy", side_effect=AssertionError):
            with self.assertLogs("Client", level="WARNING") as captured:
                _run(ctx._install_mod("install"))
        self.assertTrue(any("Close Harry Potter first" in line for line in captured.output))

    def test_install_mod_deploys_when_no_game_is_up(self) -> None:
        ctx = _Ctx(game_up=False)
        with mock.patch.object(Client.installer, "deploy", return_value=[]) as deploy:
            with self.assertLogs("Client", level="INFO"):
                _run(ctx._install_mod("install"))
        deploy.assert_called_once_with("install")


class TestGameIsUp(unittest.TestCase):
    """The real _game_is_up, with only the process probe stubbed."""

    @staticmethod
    def _ctx(writer) -> HP2Context:
        ctx = HP2Context.__new__(HP2Context)
        ctx.game_writer = writer
        return ctx

    def test_bridged_game_counts_without_probing_processes(self) -> None:
        writer = mock.Mock()
        writer.is_closing.return_value = False
        with mock.patch.object(Client, "_game_process_running", side_effect=AssertionError):
            self.assertTrue(_run(self._ctx(writer)._game_is_up()))

    def test_unbridged_game_is_read_from_the_process_list(self) -> None:
        for running in (True, False):
            with self.subTest(running=running), \
                    mock.patch.object(Client, "_game_process_running", return_value=running):
                self.assertEqual(_run(self._ctx(None)._game_is_up()), running)
