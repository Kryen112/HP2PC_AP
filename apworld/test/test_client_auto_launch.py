"""Auto-launch opens Game.exe on a connection the player asked for (the Connect
button, /connect, the startup connect) and never on the framework's automatic
retry after a dropped socket. Whether a game is already up is read from the
bridge and the process list, not from a launch flag: a game closed at its
launcher page never bridges, so nothing tied to the bridge can tell it apart
from one still running. The process probe also tells the launcher page (the
pre-engine New Game / Load Game window) from the engine by window class, so
the player is told which one to close. A mod install that could not land holds
the launch, raises the error popup when the install folder refused the write,
and repeats an in-game reminder while a game is bridged. These tests drive the
real launch step with the file work, the process probe and the spawn stubbed,
so no server, install or process is needed."""

import asyncio
import subprocess
import unittest
from unittest import mock

from CommonClient import CommonContext

from .. import Client
from ..Client import (GAME_LAUNCHER, GAME_NONE, GAME_RUNNING, GAME_UNKNOWN,
                      MOD_BLOCKED_DENIED, MOD_BLOCKED_FAILED, MOD_BLOCKED_GAME_UP,
                      HP2CommandProcessor, HP2Context)

UP_STATES = (GAME_LAUNCHER, GAME_RUNNING, GAME_UNKNOWN)
LAUNCHER_WORDING = "New Game / Load Game"


class _Ctx(HP2Context):
    """Context with only the launch-step state, recording what the real methods
    would have done instead of touching files, processes, sockets or the UI."""

    def __init__(self, game_state: str = GAME_NONE, safe: bool = True, mod_ready: bool = True) -> None:
        self._player_connect_pending = False
        self.auto_launch_override = None
        self.game_writer = None
        self.mod_install_blocked = None
        self._blocked_toast_task = None
        self.exit_event = asyncio.Event()
        self.game_state = game_state
        self.safe = safe
        self.mod_ready = mod_ready
        self.launched: list = []
        self.popups: list = []

    async def _apply_audio_randomizers(self, sd: dict):
        return self.safe, "install"

    async def _ensure_mod_current(self, install):
        return install, self.mod_ready

    async def _game_state(self) -> str:
        return self.game_state

    async def _auto_launch(self, install_hint) -> None:
        self.launched.append(install_hint)

    async def _resolve_launch_folder(self):
        return "install"

    def gui_error(self, title, text):
        self.popups.append((title, text))


class _InstallerCtx(_Ctx):
    """The launch-step stub with the real mod-current check restored, so the
    installer path runs for real down to the patched installer module."""

    _ensure_mod_current = HP2Context._ensure_mod_current


class _Processor(HP2CommandProcessor):
    def __init__(self, ctx: _Ctx) -> None:
        self.ctx = ctx
        self.lines: list = []

    def output(self, text: str) -> None:
        self.lines.append(text)


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

    def test_up_game_is_not_duplicated_and_names_what_is_up(self, *_) -> None:
        expected = {
            GAME_LAUNCHER: (LAUNCHER_WORDING, "/play"),
            GAME_RUNNING: ("Harry Potter is running", "/play"),
            GAME_UNKNOWN: ("Game.exe process", "/play"),
        }
        for state, words in expected.items():
            with self.subTest(state=state):
                ctx = _Ctx(game_state=state)
                ctx._player_connect_pending = True
                with self.assertLogs("Client", level="INFO") as captured:
                    _run(ctx._connect_audio_then_launch({}))
                self.assertEqual(ctx.launched, [])
                self.assertFalse(ctx._player_connect_pending)
                line = "\n".join(captured.output)
                for word in words:
                    self.assertIn(word, line)

    def test_launcher_page_is_never_called_the_game(self, *_) -> None:
        ctx = _Ctx(game_state=GAME_LAUNCHER)
        ctx._player_connect_pending = True
        with self.assertLogs("Client", level="INFO") as captured:
            _run(ctx._connect_audio_then_launch({}))
        self.assertNotIn("is running", "\n".join(captured.output))

    def test_unsafe_install_warns_instead_of_launching(self, *_) -> None:
        ctx = _Ctx(safe=False)
        ctx._player_connect_pending = True
        with self.assertLogs("Client", level="WARNING"):
            _run(ctx._connect_audio_then_launch({}))
        self.assertEqual(ctx.launched, [])


@mock.patch.object(Client, "_auto_install_enabled", return_value=True)
@mock.patch.object(Client, "_auto_launch_enabled", return_value=True)
class TestBlockedModInstallHoldsTheLaunch(unittest.TestCase):
    """With auto install on, a mod deploy that did not land holds the launch
    and points at /play as the override; a current or freshly deployed mod
    launches as usual."""

    def test_blocked_install_holds_the_launch(self, *_) -> None:
        ctx = _Ctx(mod_ready=False)
        ctx._player_connect_pending = True
        with self.assertLogs("Client", level="WARNING") as captured:
            _run(ctx._connect_audio_then_launch({}))
        self.assertEqual(ctx.launched, [])
        line = "\n".join(captured.output)
        self.assertIn("Not auto-launching", line)
        self.assertIn("/play", line)

    def test_ready_install_launches(self, *_) -> None:
        ctx = _Ctx(mod_ready=True)
        ctx._player_connect_pending = True
        _run(ctx._connect_audio_then_launch({}))
        self.assertEqual(ctx.launched, ["install"])


class TestAutoLaunchDisabled(unittest.TestCase):
    @mock.patch.object(Client, "_auto_install_enabled", return_value=False)
    @mock.patch.object(Client, "_auto_launch_enabled", return_value=False)
    def test_setting_off_launches_nothing_and_still_consumes_the_arm(self, *_) -> None:
        ctx = _Ctx()
        ctx._player_connect_pending = True
        _run(ctx._connect_audio_then_launch({}))
        self.assertEqual(ctx.launched, [])
        self.assertFalse(ctx._player_connect_pending)


@mock.patch.object(Client, "_auto_install_enabled", return_value=False)
class TestAutoplayCommand(unittest.TestCase):
    """/autoplay overrides the auto_launch_game setting for the client session."""

    def test_bare_flips_from_the_setting(self, *_) -> None:
        ctx = _Ctx()
        proc = _Processor(ctx)
        with mock.patch.object(Client, "_auto_launch_enabled", return_value=True):
            proc._cmd_autoplay("")
            self.assertFalse(ctx.auto_launch_wanted())
            self.assertTrue(proc.lines[-1].startswith("Auto-launch is off"))
            proc._cmd_autoplay("")
            self.assertTrue(ctx.auto_launch_wanted())
            self.assertTrue(proc.lines[-1].startswith("Auto-launch is on"))

    def test_explicit_on_off_beats_the_setting(self, *_) -> None:
        ctx = _Ctx()
        proc = _Processor(ctx)
        with mock.patch.object(Client, "_auto_launch_enabled", return_value=True):
            proc._cmd_autoplay("off")
            self.assertFalse(ctx.auto_launch_wanted())
        with mock.patch.object(Client, "_auto_launch_enabled", return_value=False):
            proc._cmd_autoplay(" ON ")
            self.assertTrue(ctx.auto_launch_wanted())

    def test_bad_argument_prints_usage_and_changes_nothing(self, *_) -> None:
        ctx = _Ctx()
        proc = _Processor(ctx)
        proc._cmd_autoplay("maybe")
        self.assertIsNone(ctx.auto_launch_override)
        self.assertTrue(proc.lines[-1].startswith("Usage: /autoplay"))

    def test_override_off_stops_a_player_connect_from_launching(self, *_) -> None:
        ctx = _Ctx()
        ctx.auto_launch_override = False
        ctx._player_connect_pending = True
        with mock.patch.object(Client, "_auto_launch_enabled", return_value=True):
            _run(ctx._connect_audio_then_launch({}))
        self.assertEqual(ctx.launched, [])

    def test_override_on_launches_with_the_setting_off(self, *_) -> None:
        ctx = _Ctx()
        ctx.auto_launch_override = True
        ctx._player_connect_pending = True
        with mock.patch.object(Client, "_auto_launch_enabled", return_value=False):
            _run(ctx._connect_audio_then_launch({}))
        self.assertEqual(ctx.launched, ["install"])


class TestConnectArmsTheLaunch(unittest.TestCase):
    def test_connect_arms_then_defers_to_the_framework(self) -> None:
        ctx = _Ctx()
        with mock.patch.object(CommonContext, "connect", new=mock.AsyncMock()) as base:
            _run(ctx.connect("host:38281"))
        self.assertTrue(ctx._player_connect_pending)
        base.assert_awaited_once_with("host:38281")


class TestInstallerRefusesWhileGameIsUp(unittest.TestCase):
    """The installer reads the same probe, so a game parked at its launcher
    page (a process, not yet bridged) blocks a deploy the way a bridged one
    does, and the refusal names the launcher window rather than "the game".
    Both installer entry points are driven, so a dropped await on the probe (a
    bare coroutine compares unequal to GAME_NONE) fails here rather than in a
    player's client."""

    def test_stale_mod_is_left_alone_while_game_is_up(self) -> None:
        for state in UP_STATES:
            with self.subTest(state=state):
                ctx = _InstallerCtx(game_state=state)
                with mock.patch.object(Client.installer, "mod_is_current", return_value=False), \
                        mock.patch.object(Client.installer, "deploy", side_effect=AssertionError):
                    with self.assertLogs("Client", level="WARNING") as captured:
                        self.assertEqual(_run(ctx._ensure_mod_current("install")), ("install", False))
                line = "\n".join(captured.output)
                self.assertIn("type /installmod", line)
                self.assertEqual(LAUNCHER_WORDING in line, state == GAME_LAUNCHER)
                self.assertEqual(ctx.mod_install_blocked, MOD_BLOCKED_GAME_UP)

    def test_stale_mod_is_deployed_when_no_game_is_up(self) -> None:
        ctx = _InstallerCtx(game_state=GAME_NONE)
        ctx.mod_install_blocked = MOD_BLOCKED_GAME_UP
        with mock.patch.object(Client.installer, "mod_is_current", return_value=False), \
                mock.patch.object(Client.installer, "deploy", return_value=[]) as deploy:
            with self.assertLogs("Client", level="INFO"):
                self.assertEqual(_run(ctx._ensure_mod_current("install")), ("install", True))
        deploy.assert_called_once_with("install")
        self.assertIsNone(ctx.mod_install_blocked)

    def test_current_mod_clears_a_stale_block(self) -> None:
        ctx = _InstallerCtx(game_state=GAME_RUNNING)
        ctx.mod_install_blocked = MOD_BLOCKED_DENIED
        with mock.patch.object(Client.installer, "mod_is_current", return_value=True):
            self.assertEqual(_run(ctx._ensure_mod_current("install")), ("install", True))
        self.assertIsNone(ctx.mod_install_blocked)

    def test_install_mod_warns_and_skips_deploy(self) -> None:
        for state in UP_STATES:
            with self.subTest(state=state):
                ctx = _Ctx(game_state=state)
                with mock.patch.object(Client.installer, "deploy", side_effect=AssertionError):
                    with self.assertLogs("Client", level="WARNING") as captured:
                        self.assertFalse(_run(ctx._install_mod("install")))
                line = "\n".join(captured.output)
                self.assertIn("then type /installmod", line)
                self.assertEqual(LAUNCHER_WORDING in line, state == GAME_LAUNCHER)
                self.assertEqual(ctx.mod_install_blocked, MOD_BLOCKED_GAME_UP)

    def test_install_mod_deploys_when_no_game_is_up(self) -> None:
        ctx = _Ctx(game_state=GAME_NONE)
        with mock.patch.object(Client.installer, "deploy", return_value=[]) as deploy:
            with self.assertLogs("Client", level="INFO"):
                self.assertTrue(_run(ctx._install_mod("install")))
        deploy.assert_called_once_with("install")
        self.assertIsNone(ctx.mod_install_blocked)


@mock.patch.object(Client, "_client_is_elevated", return_value=False)
@mock.patch.object(Client.sys, "platform", "win32")
class TestInstallerWriteDenied(unittest.TestCase):
    """A write the OS refused (or one that hangs) records the denied reason,
    logs the advice and raises the popup naming the folder; any other failure
    records a failure with no popup."""

    def test_permission_error_raises_the_popup(self, *_) -> None:
        ctx = _Ctx()
        with mock.patch.object(Client.installer, "deploy", side_effect=PermissionError(13, "Access is denied")):
            with self.assertLogs("Client", level="ERROR") as captured:
                self.assertFalse(_run(ctx._install_mod("install")))
        self.assertEqual(ctx.mod_install_blocked, MOD_BLOCKED_DENIED)
        self.assertEqual(len(ctx.popups), 1)
        title, text = ctx.popups[0]
        self.assertIn("install", text)
        self.assertIn("Run as administrator", text)
        self.assertIn("administrator", "\n".join(captured.output))

    def test_hung_write_raises_the_popup(self, *_) -> None:
        ctx = _Ctx()
        with mock.patch.object(Client.installer, "deploy", return_value=[]), \
                mock.patch.object(Client.asyncio, "wait_for", side_effect=asyncio.TimeoutError):
            with self.assertLogs("Client", level="ERROR"):
                self.assertFalse(_run(ctx._install_mod("install")))
        self.assertEqual(ctx.mod_install_blocked, MOD_BLOCKED_DENIED)
        self.assertEqual(len(ctx.popups), 1)

    def test_elevated_client_gets_different_advice(self, *_) -> None:
        ctx = _Ctx()
        with mock.patch.object(Client, "_client_is_elevated", return_value=True), \
                mock.patch.object(Client.installer, "deploy", side_effect=PermissionError(13, "Access is denied")):
            with self.assertLogs("Client", level="ERROR"):
                _run(ctx._install_mod("install"))
        _, text = ctx.popups[0]
        self.assertIn("runs as administrator", text)
        self.assertNotIn("Run as administrator", text)

    def test_other_failures_record_failed_without_a_popup(self, *_) -> None:
        for exc in (FileNotFoundError("Default.ini not found"), ValueError("no anchor")):
            with self.subTest(exc=type(exc).__name__):
                ctx = _Ctx()
                with mock.patch.object(Client.installer, "deploy", side_effect=exc):
                    with self.assertLogs("Client", level="ERROR"):
                        self.assertFalse(_run(ctx._install_mod("install")))
                self.assertEqual(ctx.mod_install_blocked, MOD_BLOCKED_FAILED)
                self.assertEqual(ctx.popups, [])

    def test_off_windows_advice_names_permissions_only(self, *_) -> None:
        with mock.patch.object(Client.sys, "platform", "linux"):
            _, text = Client._write_denied_advice("/games/hp2")
        self.assertIn("/games/hp2", text)
        self.assertNotIn("administrator", text)


@mock.patch.object(Client, "_client_is_elevated", return_value=False)
@mock.patch.object(Client.sys, "platform", "win32")
class TestRandomizerWriteDenied(unittest.TestCase):
    """A randomizer write the OS refused (or one that hangs) raises the same
    popup with one advice line, but records no mod-blocked reason: the mod
    package may well be current. Any other patch error stays a log line."""

    @staticmethod
    def _patch_sound(ctx: _Ctx) -> bool:
        ctx.audio_seed = {"sound": 1}
        ctx.audio_mode = {"sound": Client.sound_patch.ON}

        async def scenario():
            return await ctx._patch_one(asyncio.get_running_loop(), "sound", True, "install")

        return _run(scenario())

    def test_permission_error_raises_the_popup_without_a_reason(self, *_) -> None:
        ctx = _Ctx()
        with mock.patch.object(Client.sound_patch, "apply_patch", side_effect=PermissionError(13, "Access is denied")):
            with self.assertLogs("Client", level="ERROR") as captured:
                self.assertFalse(self._patch_sound(ctx))
        self.assertEqual(len(ctx.popups), 1)
        self.assertIsNone(ctx.mod_install_blocked)
        self.assertEqual(sum("administrator" in line for line in captured.output), 1)

    def test_hung_write_raises_the_popup_without_a_reason(self, *_) -> None:
        ctx = _Ctx()
        with mock.patch.object(Client.sound_patch, "apply_patch", return_value=None), \
                mock.patch.object(Client.asyncio, "wait_for", side_effect=asyncio.TimeoutError):
            with self.assertLogs("Client", level="ERROR") as captured:
                self.assertFalse(self._patch_sound(ctx))
        self.assertEqual(len(ctx.popups), 1)
        self.assertIsNone(ctx.mod_install_blocked)
        self.assertEqual(sum("administrator" in line for line in captured.output), 1)

    def test_other_patch_errors_stay_a_log_line(self, *_) -> None:
        ctx = _Ctx()
        with mock.patch.object(Client.sound_patch, "apply_patch", side_effect=Client.PatchError("bad package")):
            with self.assertLogs("Client", level="ERROR"):
                self.assertFalse(self._patch_sound(ctx))
        self.assertEqual(ctx.popups, [])
        self.assertIsNone(ctx.mod_install_blocked)


class TestBlockedReminderToast(unittest.TestCase):
    """While a blocked reason holds, the reminder is pushed to a bridged game
    on the plain TOAST verb at the blocked-toast interval, and the loop ends
    when the reason clears."""

    def test_text_by_reason(self) -> None:
        self.assertIn("/installmod", Client._blocked_toast_text(MOD_BLOCKED_GAME_UP))
        self.assertIn("administrator", Client._blocked_toast_text(MOD_BLOCKED_DENIED))
        self.assertIn("client window", Client._blocked_toast_text(MOD_BLOCKED_FAILED))

    def test_loop_repeats_until_the_reason_clears(self) -> None:
        ctx = _Ctx()
        writer = mock.Mock()
        writer.is_closing.return_value = False
        ctx.game_writer = writer

        async def scenario():
            ctx._set_mod_blocked(MOD_BLOCKED_DENIED)
            task = ctx._blocked_toast_task
            await asyncio.sleep(0.05)
            ctx._set_mod_blocked(None)
            await task

        with mock.patch.object(Client, "BLOCKED_TOAST_INTERVAL", 0.01):
            _run(scenario())
        lines = [call.args[0] for call in writer.write.call_args_list]
        self.assertGreaterEqual(len(lines), 2)
        self.assertTrue(all(line == b"TOAST AP: mod update blocked. Run the Archipelago Launcher as administrator.\n"
                            for line in lines))

    def test_setting_a_reason_twice_keeps_one_loop(self) -> None:
        ctx = _Ctx()

        async def scenario():
            ctx._set_mod_blocked(MOD_BLOCKED_GAME_UP)
            first = ctx._blocked_toast_task
            ctx._set_mod_blocked(MOD_BLOCKED_DENIED)
            self.assertIs(ctx._blocked_toast_task, first)
            ctx._set_mod_blocked(None)
            await first

        with mock.patch.object(Client, "BLOCKED_TOAST_INTERVAL", 0.01):
            _run(scenario())

    def test_no_bridged_game_drops_the_push(self) -> None:
        ctx = _Ctx()

        async def scenario():
            ctx._set_mod_blocked(MOD_BLOCKED_DENIED)
            task = ctx._blocked_toast_task
            await asyncio.sleep(0.03)
            ctx._set_mod_blocked(None)
            await task

        with mock.patch.object(Client, "BLOCKED_TOAST_INTERVAL", 0.01):
            _run(scenario())


class TestGameState(unittest.TestCase):
    """The real _game_state, with only the process probe stubbed."""

    @staticmethod
    def _ctx(writer) -> HP2Context:
        ctx = HP2Context.__new__(HP2Context)
        ctx.game_writer = writer
        return ctx

    def test_bridged_game_is_running_without_probing_processes(self) -> None:
        writer = mock.Mock()
        writer.is_closing.return_value = False
        with mock.patch.object(Client, "_game_process_state", side_effect=AssertionError):
            self.assertEqual(_run(self._ctx(writer)._game_state()), GAME_RUNNING)

    def test_unbridged_game_is_read_from_the_process_probe(self) -> None:
        for state in (GAME_NONE, GAME_LAUNCHER, GAME_RUNNING, GAME_UNKNOWN):
            with self.subTest(state=state), \
                    mock.patch.object(Client, "_game_process_state", return_value=state):
                self.assertEqual(_run(self._ctx(None)._game_state()), state)


@mock.patch.object(Client.sys, "platform", "win32")
class TestGameProcessState(unittest.TestCase):
    """The process probe classifies by the window classes Game.exe shows: the
    pre-engine front end at the launcher page, the engine viewport once a slot
    is picked. Doubt of any kind reads as a game being up."""

    FRONT_END = ["GameUnrealM212FrontEnd", "GameUnrealWM212ToolTip"]
    VIEWPORT = ["GameUnrealWWindowsViewportWindow"]

    def _state(self, pids, classes) -> str:
        with mock.patch.object(Client, "_game_process_ids", return_value=pids), \
                mock.patch.object(Client, "_visible_window_classes", return_value=classes) as walk:
            state = Client._game_process_state()
            if pids:
                walk.assert_called_once_with(pids)
            else:
                walk.assert_not_called()
        return state

    def test_no_process_is_none(self, *_) -> None:
        self.assertEqual(self._state(set(), None), GAME_NONE)

    def test_front_end_window_alone_is_the_launcher_page(self, *_) -> None:
        self.assertEqual(self._state({15148}, self.FRONT_END), GAME_LAUNCHER)

    def test_engine_viewport_is_running_even_beside_the_front_end(self, *_) -> None:
        self.assertEqual(self._state({15148}, self.VIEWPORT), GAME_RUNNING)
        self.assertEqual(self._state({15148}, self.FRONT_END + self.VIEWPORT), GAME_RUNNING)

    def test_process_without_either_window_is_unknown(self, *_) -> None:
        self.assertEqual(self._state({15148}, []), GAME_UNKNOWN)
        self.assertEqual(self._state({15148}, None), GAME_UNKNOWN)

    def test_tasklist_failure_is_unknown(self, *_) -> None:
        self.assertEqual(self._state(None, None), GAME_UNKNOWN)

    def test_off_windows_never_blocks(self, *_) -> None:
        with mock.patch.object(Client.sys, "platform", "linux"), \
                mock.patch.object(Client, "_game_process_ids", side_effect=AssertionError):
            self.assertEqual(Client._game_process_state(), GAME_NONE)


class TestGameProcessIds(unittest.TestCase):
    """tasklist rows are parsed as bytes in CSV form, so a localized no-match
    notice and a non-ASCII console codepage never read as a running game."""

    def _ids(self, stdout: bytes):
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout=stdout, stderr=b"")
        with mock.patch.object(Client.subprocess, "CREATE_NO_WINDOW", 0, create=True), \
                mock.patch.object(Client.subprocess, "run", return_value=completed):
            return Client._game_process_ids()

    def test_rows_yield_pids(self) -> None:
        stdout = (b'"Game.exe","15148","Console","4","80.280 K"\r\n'
                  b'"Game.exe","2004","Console","4","1.000 K"\r\n')
        self.assertEqual(self._ids(stdout), {15148, 2004})

    def test_no_match_notice_yields_no_pids(self) -> None:
        self.assertEqual(self._ids(b"INFO: Er worden geen taken uitgevoerd die voldoen aan de criteria.\r\n"), set())
        self.assertEqual(self._ids(b""), set())

    def test_other_images_are_ignored(self) -> None:
        self.assertEqual(self._ids(b'"UnrealEd.exe","77","Console","4","80.280 K"\r\n'), set())

    def test_probe_failure_is_none(self) -> None:
        for exc in (OSError(), subprocess.TimeoutExpired(cmd="tasklist", timeout=3)):
            with self.subTest(exc=type(exc).__name__), \
                    mock.patch.object(Client.subprocess, "CREATE_NO_WINDOW", 0, create=True), \
                    mock.patch.object(Client.subprocess, "run", side_effect=exc):
                self.assertIsNone(Client._game_process_ids())


if __name__ == "__main__":
    unittest.main()
