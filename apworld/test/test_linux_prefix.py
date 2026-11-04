"""Linux support: the game runs inside a Wine or Proton prefix, so its Documents
folder (Game.ini, saves, the game link folder) is the prefix's
drive_c/users/<user>/Documents, found from the install path. The client reads
that folder through the prefix, while Game.ini carries the Windows form of the
path the game sees. Game.exe starts through wine with the prefix as
WINEPREFIX. These tests build a fake prefix in a temp folder and run with the
platform patched to Linux."""
import asyncio
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from .. import Client, installer
from ..Client import HP2Context

PACKAGE_BYTES = b"canonical compiled package"
DEFAULT_INI = "[Engine.Engine]\nConsole=HGame.HPConsole\nDefaultGame=Engine.GameInfo\n"


class PrefixCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.prefix = self.root / "pfx"
        self.drive_c = self.prefix / "drive_c"
        self.install = self.drive_c / "Games" / "HP2"
        (self.install / "system").mkdir(parents=True)
        (self.install / "system" / "Default.ini").write_text(DEFAULT_INI, encoding="ascii")
        (self.drive_c / "users" / "Public" / "Documents").mkdir(parents=True)
        packaged = self.root / "HPArchipelago.u"
        packaged.write_bytes(PACKAGE_BYTES)
        self._patches = [
            mock.patch.object(installer.sys, "platform", "linux"),
            mock.patch.object(installer, "MOD_PACKAGE_DATA", packaged),
        ]
        for patch in self._patches:
            patch.start()

    def tearDown(self) -> None:
        for patch in self._patches:
            patch.stop()
        self._tmp.cleanup()

    def add_user(self, name: str, documents: str = "Documents", with_game_folder: bool = False) -> Path:
        folder = self.drive_c / "users" / name / documents
        folder.mkdir(parents=True)
        if with_game_folder:
            (folder / installer.USER_INI_DIR_NAME).mkdir()
        return folder


class TestPrefixDiscovery(PrefixCase):
    def test_prefix_is_the_folder_holding_drive_c(self) -> None:
        self.assertEqual(installer.wine_prefix(self.install), self.prefix)
        self.assertIsNone(installer.wine_prefix(self.root / "elsewhere" / "HP2"))

    def test_single_user_is_picked_and_public_is_ignored(self) -> None:
        documents = self.add_user("steamuser")
        self.assertEqual(installer.channel_dir(self.install),
                         documents / installer.USER_INI_DIR_NAME / installer.CHANNEL_DIR_NAME)

    def test_user_with_the_game_folder_wins(self) -> None:
        self.add_user("steamuser")
        documents = self.add_user("player", with_game_folder=True)
        self.assertEqual(installer.channel_dir(self.install).parent.parent, documents)

    def test_steamuser_breaks_a_tie(self) -> None:
        self.add_user("alice")
        documents = self.add_user("steamuser")
        self.assertEqual(installer.channel_dir(self.install).parent.parent, documents)

    def test_older_my_documents_folder_is_used(self) -> None:
        documents = self.add_user("player", documents="My Documents")
        self.assertEqual(installer.channel_dir(self.install).parent.parent, documents)

    def test_ambiguous_users_raise(self) -> None:
        self.add_user("alice")
        self.add_user("bob")
        with self.assertRaises(ValueError):
            installer.channel_dir(self.install)

    def test_install_outside_a_prefix_raises(self) -> None:
        with self.assertRaises(ValueError):
            installer.channel_dir(self.root / "HP2")

    def test_no_install_raises_off_windows(self) -> None:
        with self.assertRaises(ValueError):
            installer.channel_dir()


class TestPrefixDeploy(PrefixCase):
    def test_deploy_wires_the_windows_form_of_the_channel(self) -> None:
        documents = self.add_user("steamuser", with_game_folder=True)
        game_ini = documents / installer.USER_INI_DIR_NAME / "Game.ini"
        game_ini.write_text(DEFAULT_INI, encoding="ascii")
        installer.deploy(self.install)
        expected = "ChannelDir=C:\\users\\steamuser\\Documents\\Harry Potter II\\AP"
        for ini in (self.install / "system" / "Default.ini", game_ini):
            with self.subTest(ini=ini.name):
                self.assertIn(expected, ini.read_text(encoding="latin-1").splitlines())
        self.assertTrue((documents / installer.USER_INI_DIR_NAME / installer.CHANNEL_DIR_NAME).is_dir())
        self.assertTrue(installer.mod_is_current(self.install))

    def test_deploy_outside_a_prefix_fails_clearly(self) -> None:
        outside = self.root / "HP2"
        (outside / "system").mkdir(parents=True)
        (outside / "system" / "Default.ini").write_text(DEFAULT_INI, encoding="ascii")
        with self.assertRaisesRegex(ValueError, "not inside a Wine or Proton prefix"):
            installer.deploy(outside)
        self.assertFalse((outside / "system" / "HPArchipelago.u").exists())
        self.assertFalse(installer.mod_is_current(outside))

    def test_game_side_path_uses_the_innermost_drive_c_in_any_case(self) -> None:
        channel = self.root / "drive_c" / "nested" / "Drive_C" / "users" / "steamuser" / "AP"
        self.assertEqual(installer._game_side_path(channel), "C:\\users\\steamuser\\AP")


class TestWineLaunchCommand(PrefixCase):
    def test_windows_starts_the_exe_directly(self) -> None:
        with mock.patch.object(Client.sys, "platform", "win32"):
            self.assertEqual(Client._launch_command("install", "Game.exe"), (["Game.exe"], None, ""))

    def test_linux_starts_through_wine_with_the_prefix(self) -> None:
        exe = str(self.install / "system" / "Game.exe")
        with mock.patch.object(Client.sys, "platform", "linux"), \
                mock.patch.object(Client.shutil, "which", return_value="/usr/bin/wine"):
            argv, env, problem = Client._launch_command(str(self.install), exe)
        self.assertEqual(argv, ["/usr/bin/wine", exe])
        self.assertEqual(env["WINEPREFIX"], str(self.prefix))
        self.assertEqual(problem, "")

    def test_proton_prefix_is_left_to_steam(self) -> None:
        proton = self.root / "compatdata" / "123" / "pfx"
        install = proton / "drive_c" / "HP2"
        install.mkdir(parents=True)
        (proton.parent / "version").write_text("8.0", encoding="ascii")
        with mock.patch.object(Client.sys, "platform", "linux"), \
                mock.patch.object(Client.shutil, "which", return_value="/usr/bin/wine"):
            argv, _, problem = Client._launch_command(str(install), "Game.exe")
        self.assertIsNone(argv)
        self.assertIn("Steam", problem)

    def test_missing_wine_or_prefix_is_a_problem_not_a_launch(self) -> None:
        with mock.patch.object(Client.sys, "platform", "linux"), \
                mock.patch.object(Client.shutil, "which", return_value=None):
            argv, _, problem = Client._launch_command(str(self.install), "Game.exe")
        self.assertIsNone(argv)
        self.assertIn("wine", problem)
        with mock.patch.object(Client.sys, "platform", "linux"):
            argv, _, problem = Client._launch_command(str(self.root / "HP2"), "Game.exe")
        self.assertIsNone(argv)
        self.assertIn("prefix", problem)


class TestLaunchGame(PrefixCase):
    """_launch_game spawns what _launch_command returns, and logs instead of
    spawning when there is no way to launch."""

    def _ctx(self) -> HP2Context:
        ctx = HP2Context.__new__(HP2Context)
        ctx.is_open_castle = False
        return ctx

    def test_linux_launch_passes_the_prefix_to_wine(self) -> None:
        with mock.patch.object(Client.os.path, "exists", return_value=True), \
                mock.patch.object(Client.sys, "platform", "linux"), \
                mock.patch.object(Client.shutil, "which", return_value="/usr/bin/wine"), \
                mock.patch.object(Client.subprocess, "Popen") as popen:
            with self.assertLogs("Client", level="INFO"):
                self._ctx()._launch_game(str(self.install))
        self.assertEqual(popen.call_args.kwargs["env"]["WINEPREFIX"], str(self.prefix))
        self.assertEqual(popen.call_args.args[0][0], "/usr/bin/wine")

    def test_no_way_to_launch_logs_and_spawns_nothing(self) -> None:
        with mock.patch.object(Client.os.path, "exists", return_value=True), \
                mock.patch.object(Client.sys, "platform", "linux"), \
                mock.patch.object(Client.shutil, "which", return_value=None), \
                mock.patch.object(Client.subprocess, "Popen") as popen:
            with self.assertLogs("Client", level="ERROR") as captured:
                self._ctx()._launch_game(str(self.install))
        popen.assert_not_called()
        self.assertIn("auto_launch_game: false", "\n".join(captured.output))


class TestLinkChannel(PrefixCase):
    """The link folder waits for the install folder off Windows and warns once
    when the install cannot give one."""

    def _ctx(self) -> HP2Context:
        ctx = HP2Context.__new__(HP2Context)
        ctx.is_open_castle = False
        ctx.seed_mode = "vanilla"
        ctx._link_channel_warned = False
        ctx.exit_event = asyncio.Event()
        return ctx

    def test_windows_needs_no_install(self) -> None:
        with mock.patch.object(Client.sys, "platform", "win32"), \
                mock.patch.object(Client.installer, "channel_dir", return_value=Path("C:/AP")) as channel:
            self.assertEqual(self._ctx()._link_channel(), str(Path("C:/AP")))
        channel.assert_called_once_with()

    def test_linux_waits_for_the_seed(self) -> None:
        ctx = self._ctx()
        ctx.seed_mode = None
        with mock.patch.object(Client.sys, "platform", "linux"), \
                mock.patch.object(Client, "_hp2_install_path", side_effect=AssertionError):
            self.assertIsNone(ctx._link_channel())

    def test_link_wait_ends_when_the_client_exits(self) -> None:
        ctx = self._ctx()
        ctx.exit_event.set()
        with mock.patch.object(HP2Context, "_link_channel", return_value=None), \
                mock.patch.object(Client, "FileGameLink", side_effect=AssertionError):
            asyncio.run(ctx.run_game_link())

    def test_linux_waits_for_the_install_folder(self) -> None:
        with mock.patch.object(Client.sys, "platform", "linux"), \
                mock.patch.object(Client, "_hp2_install_path", return_value=None):
            self.assertIsNone(self._ctx()._link_channel())

    def test_linux_finds_the_folder_in_the_prefix(self) -> None:
        documents = self.add_user("steamuser")
        with mock.patch.object(Client.sys, "platform", "linux"), \
                mock.patch.object(Client, "_hp2_install_path", return_value=str(self.install)):
            self.assertEqual(self._ctx()._link_channel(),
                             str(documents / installer.USER_INI_DIR_NAME / installer.CHANNEL_DIR_NAME))

    def test_bad_install_warns_once(self) -> None:
        ctx = self._ctx()
        with mock.patch.object(Client.sys, "platform", "linux"), \
                mock.patch.object(Client, "_hp2_install_path", return_value=str(self.root / "HP2")):
            with self.assertLogs("Client", level="WARNING") as captured:
                self.assertIsNone(ctx._link_channel())
                self.assertIsNone(ctx._link_channel())
        self.assertEqual(len(captured.output), 1)

    def test_link_starts_once_the_folder_is_known(self) -> None:
        ctx = self._ctx()
        answers = iter([None, None, str(self.root / "AP")])
        started = []

        class _Link:
            def __init__(self, channel):
                started.append(channel)

            async def run(self, *_):
                return None

        with mock.patch.object(HP2Context, "_link_channel", side_effect=lambda: next(answers)), \
                mock.patch.object(Client, "LINK_CHANNEL_RETRY_SECONDS", 0), \
                mock.patch.object(Client, "FileGameLink", _Link):
            asyncio.run(ctx.run_game_link())
        self.assertEqual(started, [self.root / "AP"])


if __name__ == "__main__":
    unittest.main()
