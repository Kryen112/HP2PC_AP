"""The borderless window: before launch the game is set to open windowed at
the monitor's size; once it runs, the frame is hidden and the area the game
draws in is centered, without the window changing size or style, and the client
keeps it that way while the game is connected, giving up when the game keeps
putting the frame back."""

import asyncio
import shutil
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Optional
from unittest import mock

from .. import Client, HP2Settings, borderless, installer
from ..Client import BORDERLESS_MAX_REAPPLIES, ENGINE_WINDOW_CLASS, HP2Context
from ..borderless import CHANGED, GONE, REFUSED, UNCHANGED

MONITOR = (0, 0, 2560, 1440)
CLIENT_SIZE = (2048, 1152)
CENTERED = (256, 144, 2304, 1296)
# A framed window: 8 pixels of border at the sides, a 31 pixel title bar.
WINDOW = (100, 100, 2164, 1291)
CLIENT_ORIGIN = (108, 131)
REGION = (8, 31, 2056, 1183)
CORNER = (248, 113)
FRAME_OFF_THEN_BACK = [(borderless.DWMWA_NCRENDERING_POLICY, borderless.DWMNCRP_DISABLED),
                       (borderless.DWMWA_NCRENDERING_POLICY, borderless.DWMNCRP_USEWINDOWSTYLE)]


class TestWindowPlacement(unittest.TestCase):
    def test_placement_clips_to_the_drawing_area_and_centers_it(self) -> None:
        self.assertEqual(borderless.placement(WINDOW, CLIENT_ORIGIN, CLIENT_SIZE, MONITOR), (REGION, CORNER))

    def test_placement_on_a_second_monitor(self) -> None:
        region, corner = borderless.placement((2000, 50, 3936, 1170), (2008, 81), (1920, 1080),
                                              (1920, 0, 3840, 1080))
        self.assertEqual(region, (8, 31, 1928, 1111))
        self.assertEqual(corner, (1912, -31))

    def test_smaller_window_is_centered(self) -> None:
        self.assertEqual(borderless.centered_rect(*CLIENT_SIZE, MONITOR), CENTERED)

    def test_monitor_sized_window_fills_it(self) -> None:
        self.assertEqual(borderless.centered_rect(1920, 1080, (1920, 0, 3840, 1080)), (1920, 0, 3840, 1080))

    def test_larger_window_keeps_its_corner_on_the_monitor(self) -> None:
        self.assertEqual(borderless.centered_rect(2048, 1200, (0, 0, 1920, 1080)), (0, 0, 2048, 1200))

    def test_monitor_up_to_the_widest_is_used_as_is(self) -> None:
        self.assertEqual(borderless.windowed_size(1920, 1080), (1920, 1080))
        self.assertEqual(borderless.windowed_size(2048, 1536), (2048, 1536))

    def test_scaled_display_hands_the_game_scaled_down_pixels(self) -> None:
        self.assertEqual(borderless.game_pixels(2560, 1440, 96), (2560, 1440))
        self.assertEqual(borderless.game_pixels(2560, 1440, 120), (2048, 1152))
        self.assertEqual(borderless.game_pixels(1920, 1080, 144), (1280, 720))

    def test_wider_monitor_scales_down_keeping_its_shape(self) -> None:
        self.assertEqual(borderless.windowed_size(2560, 1440), (2048, 1152))
        self.assertEqual(borderless.windowed_size(3440, 1440), (2048, 857))


class TestWindowedSizeSetting(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="hp2_window_"))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.install = self.root / "install"
        (self.install / "system").mkdir(parents=True)
        self.user = self.root / "user"
        self.user.mkdir()
        patcher = mock.patch.object(installer, "_user_ini_dir", return_value=self.user)
        patcher.start()
        self.addCleanup(patcher.stop)

    @staticmethod
    def write(path: Path, text: str) -> None:
        path.write_bytes(text.replace("\n", "\r\n").encode("latin-1"))

    def test_game_ini_gets_the_size_and_windowed_mode(self) -> None:
        game_ini = self.user / "Game.ini"
        self.write(game_ini, "[WinDrv.WindowsClient]\nWindowedViewportX=640\nWindowedViewportY=480\n"
                             "StartupFullscreen=True\n[XDrv.XClient]\nWindowedViewportX=640\n")
        self.assertTrue(installer.set_windowed_size(self.install, 1920, 1080))
        text = game_ini.read_bytes().decode("latin-1")
        self.assertIn("[WinDrv.WindowsClient]\r\nWindowedViewportX=1920\r\nWindowedViewportY=1080\r\n"
                      "StartupFullscreen=False\r\n", text)
        self.assertIn("[XDrv.XClient]\r\nWindowedViewportX=640", text)
        self.assertTrue((self.user / installer.BACKUP_DIR_NAME / "Game.ini").is_file())
        self.assertFalse(installer.set_windowed_size(self.install, 1920, 1080))

    def test_default_ini_before_the_first_launch(self) -> None:
        default_ini = self.install / "system" / "Default.ini"
        self.write(default_ini, "[Engine.Engine]\nGameEngine=Engine.GameEngine\n")
        self.assertTrue(installer.set_windowed_size(self.install, 1920, 1080))
        self.assertIn("[WinDrv.WindowsClient]\r\nWindowedViewportX=1920",
                      default_ini.read_bytes().decode("latin-1"))
        self.assertTrue((self.install / installer.BACKUP_DIR_NAME / "Default.ini").is_file())

    def test_missing_install_raises(self) -> None:
        with self.assertRaises(FileNotFoundError):
            installer.set_windowed_size(self.install, 1920, 1080)

    def test_client_sizes_the_window_from_the_monitor(self) -> None:
        with mock.patch.object(borderless, "primary_monitor_size", return_value=(2560, 1440)), \
                mock.patch.object(installer, "set_windowed_size", return_value=True) as setter:
            with self.assertNoLogs("Client", level="INFO"), \
                    self.assertLogs("HP2Client", level="INFO") as logs:
                Client._size_window_for_borderless(str(self.install))
        setter.assert_called_once_with(self.install, 2048, 1152)
        self.assertIn("2048x1152", logs.output[0])

    def test_client_reports_a_failure_without_raising(self) -> None:
        with mock.patch.object(borderless, "primary_monitor_size", return_value=(1920, 1080)):
            with self.assertLogs("Client", level="WARNING") as logs:
                Client._size_window_for_borderless(str(self.install))
        self.assertIn("could not set", logs.output[0])


class TestBorderlessSetting(unittest.TestCase):
    def test_on_by_default(self) -> None:
        group = HP2Settings()
        with mock.patch.object(Client, "HP2World", SimpleNamespace(settings=group)):
            self.assertTrue(Client._borderless_enabled())

    def test_off_when_set_false(self) -> None:
        group = HP2Settings()
        group.update({"borderless_window": False})
        with mock.patch.object(Client, "HP2World", SimpleNamespace(settings=group)):
            self.assertFalse(Client._borderless_enabled())


class _FakeWindows:
    """Stands in for user32, gdi32 and dwmapi: one framed window of a class on
    a monitor. Records every region, move and compositor change, and never
    lets the window's size or style change."""

    def __init__(self, class_name: str = "HGame" + ENGINE_WINDOW_CLASS, alive: bool = True,
                 minimized: bool = False, region_works: bool = True, move_works: bool = True) -> None:
        self.class_name = class_name
        self.alive = alive
        self.minimized = minimized
        self.region_works = region_works
        self.move_works = move_works
        self.out_of_regions = False
        self.compositor_fails = False
        self.window = WINDOW
        self.region: "Optional[tuple]" = None
        self.regions: "list[tuple]" = []
        self.moves: "list[tuple]" = []
        self.compositor: "list[tuple]" = []
        self.dpi_contexts: list = []
        self.deleted = 0

    # user32
    def GetWindowDpiAwarenessContext(self, _hwnd):
        return 18

    def SetThreadDpiAwarenessContext(self, context):
        self.dpi_contexts.append(context)
        return 7 if len(self.dpi_contexts) == 1 else 0

    def IsWindow(self, _hwnd):
        return self.alive

    def GetClassNameW(self, _hwnd, buffer, _size):
        buffer.value = self.class_name
        return len(self.class_name)

    def IsIconic(self, _hwnd):
        return self.minimized

    def MonitorFromWindow(self, _hwnd, _flags):
        return 1

    def GetMonitorInfoW(self, _monitor, info):
        rect = info._obj.rcMonitor
        rect.left, rect.top, rect.right, rect.bottom = MONITOR
        return 1

    def GetWindowRect(self, _hwnd, rect):
        rect._obj.left, rect._obj.top, rect._obj.right, rect._obj.bottom = self.window
        return 1

    def GetClientRect(self, _hwnd, rect):
        rect._obj.left, rect._obj.top, rect._obj.right, rect._obj.bottom = (0, 0) + CLIENT_SIZE
        return 1

    def ClientToScreen(self, _hwnd, point):
        point._obj.x = self.window[0] + REGION[0]
        point._obj.y = self.window[1] + REGION[1]
        return 1

    def GetWindowRgn(self, _hwnd, region):
        if self.region is None:
            return 0
        region[:] = list(self.region)
        return borderless.SIMPLEREGION

    def SetWindowRgn(self, _hwnd, region, _redraw):
        if not self.region_works:
            return 0
        self.region = None if region is None else tuple(region)
        self.regions.append(self.region)
        return 1

    def SetWindowPos(self, _hwnd, _after, left, top, _width, _height, flags):
        assert flags & borderless.SWP_NOSIZE
        if not self.move_works:
            return 0
        width, height = self.window[2] - self.window[0], self.window[3] - self.window[1]
        self.window = (left, top, left + width, top + height)
        self.moves.append((left, top))
        return 1

    # gdi32
    def CreateRectRgn(self, *box):
        return None if self.out_of_regions and box != (0, 0, 0, 0) else list(box)

    def GetRgnBox(self, region, rect):
        rect._obj.left, rect._obj.top, rect._obj.right, rect._obj.bottom = region

    def DeleteObject(self, _region):
        self.deleted += 1
        return 1

    # dwmapi
    def DwmSetWindowAttribute(self, _hwnd, attribute, value, _size):
        if self.compositor_fails:
            raise OSError("no compositor")
        self.compositor.append((attribute, value._obj.value))
        return 0


class TestMakeBorderless(unittest.TestCase):
    def run_make(self, fake: _FakeWindows) -> str:
        with mock.patch.object(borderless, "_user32", return_value=fake), \
                mock.patch.object(borderless, "_gdi32", return_value=fake), \
                mock.patch.object(borderless, "_dwmapi", return_value=fake):
            return borderless.make_borderless(1, ENGINE_WINDOW_CLASS)

    def test_frame_is_hidden_and_the_drawing_area_centered(self) -> None:
        fake = _FakeWindows()
        self.assertEqual(self.run_make(fake), CHANGED)
        self.assertEqual(fake.compositor, [(borderless.DWMWA_NCRENDERING_POLICY, borderless.DWMNCRP_DISABLED)])
        self.assertEqual(fake.regions, [REGION])
        self.assertEqual(fake.moves, [CORNER])
        self.assertEqual(fake.window[2] - fake.window[0], WINDOW[2] - WINDOW[0])
        self.assertEqual(fake.dpi_contexts, [18, 7])
        # Only the lookup's own region is freed; the clip now belongs to Windows.
        self.assertEqual(fake.deleted, 1)

    def test_moved_window_is_centered_again(self) -> None:
        fake = _FakeWindows()
        self.run_make(fake)
        fake.window = (0, 0, WINDOW[2] - WINDOW[0], WINDOW[3] - WINDOW[1])
        self.assertEqual(self.run_make(fake), CHANGED)
        self.assertEqual(fake.moves[-1], CORNER)

    def test_missing_compositor_still_clips_and_moves(self) -> None:
        fake = _FakeWindows()
        fake.compositor_fails = True
        self.assertEqual(self.run_make(fake), CHANGED)
        self.assertEqual(fake.regions, [REGION])
        self.assertEqual(fake.moves, [CORNER])

    def test_region_that_cannot_be_made_changes_nothing(self) -> None:
        fake = _FakeWindows()
        fake.out_of_regions = True
        self.assertEqual(self.run_make(fake), UNCHANGED)
        self.assertEqual(fake.regions, [])
        self.assertEqual(fake.moves, [])
        self.assertEqual(fake.compositor, [])

    def test_borderless_window_is_left_alone(self) -> None:
        fake = _FakeWindows()
        self.run_make(fake)
        self.assertEqual(self.run_make(fake), UNCHANGED)
        self.assertEqual(len(fake.regions), 1)
        self.assertEqual(len(fake.moves), 1)

    def test_minimized_window_is_left_alone(self) -> None:
        fake = _FakeWindows(minimized=True)
        self.assertEqual(self.run_make(fake), UNCHANGED)
        self.assertEqual(fake.regions, [])

    def test_closed_window_is_gone(self) -> None:
        self.assertEqual(self.run_make(_FakeWindows(alive=False)), GONE)

    def test_handle_of_another_window_is_gone(self) -> None:
        fake = _FakeWindows(class_name="Notepad")
        self.assertEqual(self.run_make(fake), GONE)
        self.assertEqual(fake.regions, [])

    def test_refused_region_frees_it_and_moves_nothing(self) -> None:
        fake = _FakeWindows(region_works=False)
        self.assertEqual(self.run_make(fake), REFUSED)
        self.assertEqual(fake.moves, [])
        self.assertEqual(fake.deleted, 2)
        self.assertEqual(fake.compositor, FRAME_OFF_THEN_BACK)

    def test_refused_move_is_reported_and_the_clip_undone(self) -> None:
        fake = _FakeWindows(move_works=False)
        self.assertEqual(self.run_make(fake), REFUSED)
        self.assertEqual(fake.regions, [REGION, None])
        self.assertEqual(fake.compositor, FRAME_OFF_THEN_BACK)

    def test_window_closing_mid_change_is_gone(self) -> None:
        fake = _FakeWindows(move_works=False)
        fake.IsWindow = lambda _hwnd: not fake.regions
        self.assertEqual(self.run_make(fake), GONE)


@mock.patch.object(Client, "BORDERLESS_CHECK_SECONDS", 0)
class TestBorderlessLoop(unittest.TestCase):
    def run_loop(self, results: list, rounds: int,
                 clock: Optional["list[float]"] = None) -> "tuple[mock.Mock, mock.Mock]":
        """Run the loop for a number of rounds against make_borderless results,
        then disconnect the game. Returns the make_borderless and window
        lookup mocks."""
        link = object()
        context = SimpleNamespace(game_writer=link, exit_event=asyncio.Event())
        calls = {"count": 0}

        def make(_hwnd, _class_suffix):
            calls["count"] += 1
            if calls["count"] >= rounds:
                context.game_writer = None
            return results[min(calls["count"], len(results)) - 1]

        times = iter(clock or [])
        with mock.patch.object(Client, "_engine_window", return_value=42) as lookup, \
                mock.patch.object(borderless, "make_borderless", side_effect=make) as maker, \
                mock.patch.object(Client, "_now", side_effect=lambda: next(times, 0.0)):
            asyncio.run(HP2Context._borderless_loop(context, link))
        return maker, lookup

    def test_window_made_borderless_once_and_logged_once(self) -> None:
        with self.assertNoLogs("Client", level="INFO"), \
                self.assertLogs("HP2Client", level="INFO") as logs:
            maker, lookup = self.run_loop([CHANGED, UNCHANGED, UNCHANGED], rounds=3)
        self.assertEqual(maker.call_count, 3)
        lookup.assert_called_once_with()
        self.assertEqual(sum("without a border" in line for line in logs.output), 1)

    def test_gives_up_when_the_frame_keeps_coming_back(self) -> None:
        with self.assertLogs("Client", level="WARNING") as logs:
            maker, _ = self.run_loop([CHANGED], rounds=50)
        self.assertEqual(maker.call_count, BORDERLESS_MAX_REAPPLIES + 1)
        self.assertIn("keeps putting its border back", logs.output[0])

    def test_occasional_reframes_never_give_up(self) -> None:
        maker, _ = self.run_loop([CHANGED], rounds=10, clock=[index * 60.0 for index in range(10)])
        self.assertEqual(maker.call_count, 10)

    def test_window_that_closed_is_looked_up_again(self) -> None:
        _, lookup = self.run_loop([GONE, UNCHANGED], rounds=2)
        self.assertEqual(lookup.call_count, 2)

    def test_refusal_is_reported_once_and_stops(self) -> None:
        with self.assertLogs("Client", level="WARNING") as logs:
            maker, _ = self.run_loop([REFUSED], rounds=50)
        self.assertEqual(maker.call_count, 1)
        self.assertIn("as administrator", logs.output[0])

    def test_client_exit_ends_the_loop(self) -> None:
        link = object()
        context = SimpleNamespace(game_writer=link, exit_event=asyncio.Event())
        context.exit_event.set()
        with mock.patch.object(Client, "_engine_window") as lookup:
            asyncio.run(HP2Context._borderless_loop(context, link))
        lookup.assert_not_called()

    def test_crash_is_reported_not_raised(self) -> None:
        link = object()
        context = SimpleNamespace(game_writer=link, exit_event=asyncio.Event())
        with mock.patch.object(Client, "_engine_window", side_effect=OSError("denied")):
            with self.assertLogs("Client", level="ERROR") as logs:
                asyncio.run(HP2Context._borderless_loop(context, link))
        self.assertIn("borderless crashed", logs.output[0])


class TestBorderlessStart(unittest.TestCase):
    def connect(self, enabled: bool, running: Optional[mock.Mock] = None) -> mock.Mock:
        context = mock.Mock(pending_grants=[], _borderless_task=running)
        context._borderless_loop = mock.Mock(side_effect=lambda link: asyncio.sleep(0))
        with mock.patch.object(Client, "_borderless_enabled", return_value=enabled), \
                mock.patch.object(Client.sys, "platform", "win32"):
            async def run():
                await HP2Context._on_game_connected(context, mock.Mock(game_session=1))
                if isinstance(context._borderless_task, asyncio.Task):
                    await context._borderless_task
            asyncio.run(run())
        return context

    def test_connect_starts_the_loop_when_enabled(self) -> None:
        self.connect(True)._borderless_loop.assert_called_once()

    def test_connect_leaves_the_window_alone_when_disabled(self) -> None:
        context = self.connect(False)
        context._borderless_loop.assert_not_called()
        self.assertIsNone(context._borderless_task)

    def test_running_loop_is_not_started_twice(self) -> None:
        running = mock.Mock(done=mock.Mock(return_value=False))
        context = self.connect(True, running)
        context._borderless_loop.assert_not_called()
        self.assertIs(context._borderless_task, running)

    def test_finished_loop_is_started_again(self) -> None:
        finished = mock.Mock(done=mock.Mock(return_value=True))
        self.connect(True, finished)._borderless_loop.assert_called_once()
