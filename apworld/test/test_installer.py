"""Contract tests for the mod installer's deploy step, against a throwaway
install tree: the engine settings and the channel folder land in Default.ini
and in an existing per-user Game.ini, the player's own settings survive,
deploys are idempotent, and the backups are written once.
"""
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from .. import installer

PACKAGE_BYTES = b"canonical compiled package"

DEFAULT_INI = """[URL]
Protocol=unreal

[Engine.Engine]
GameRenderDevice=D3DDrv.D3DRenderDevice
Language=int
Console=HGame.HPConsole
DefaultGame=Engine.GameInfo

[Engine.GameInfo]
bLowGore=True

[ATI 3D Rage Pro]
UseTrilinear=0
"""

GAME_INI = """[Engine.Engine]
Console=HGame.HPConsole
DefaultGame=Engine.GameInfo

[WinDrv.WindowsClient]
WindowedViewportX=1024
StartupFullscreen=False
"""


class InstallerCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.install = root / "Harry Potter 2"
        self.system = self.install / "system"
        self.system.mkdir(parents=True)
        self.default_ini = self.system / "Default.ini"
        self.default_ini.write_text(DEFAULT_INI, encoding="ascii")
        self.user_dir = root / "Documents" / "Harry Potter II"
        self.user_dir.mkdir(parents=True)
        self.channel = str(self.user_dir / installer.CHANNEL_DIR_NAME)
        packaged = root / "packaged" / "HPArchipelago.u"
        packaged.parent.mkdir()
        packaged.write_bytes(PACKAGE_BYTES)
        self._patches = [
            mock.patch.object(installer, "MOD_PACKAGE_DATA", packaged),
            mock.patch.object(installer, "_user_ini_dir", return_value=self.user_dir),
            mock.patch.object(installer, "_short_path", side_effect=str),
            # Temp folders are long; the limit itself is pinned in TestLongChannelPath.
            mock.patch.object(installer, "MAX_CHANNEL_PATH_CHARS", 1000),
        ]
        for patch in self._patches:
            patch.start()

    def tearDown(self) -> None:
        for patch in self._patches:
            patch.stop()
        self._tmp.cleanup()

    def lines(self, path: Path) -> "list[str]":
        return path.read_text(encoding="latin-1").splitlines()

    def section(self, path: Path, header: str) -> "list[str]":
        out, inside = [], False
        for line in self.lines(path):
            if line.startswith("["):
                inside = line == header
                continue
            if inside and line:
                out.append(line)
        return out


class TestDeploy(InstallerCase):
    def test_deploy_wires_everything(self) -> None:
        log = installer.deploy(self.install)
        self.assertEqual((self.system / "HPArchipelago.u").read_bytes(), PACKAGE_BYTES)
        engine = self.section(self.default_ini, "[Engine.Engine]")
        self.assertIn("DefaultGame=HPArchipelago.APGameInfo", engine)
        self.assertIn("Console=HPArchipelago.APConsole", engine)
        self.assertEqual(self.section(self.default_ini, "[HPArchipelago.APIPCActor]"),
                         ["ChannelDir=" + self.channel])
        self.assertTrue(Path(self.channel).is_dir())
        self.assertEqual(log, ["Copied the compiled mod package.", "Pointed Default.ini at the mod."])

    def test_texture_precache_is_turned_off(self) -> None:
        installer.deploy(self.install)
        self.assertEqual(self.section(self.default_ini, "[D3DDrv.D3DRenderDevice]"), ["UsePrecache=False"])

    def test_texture_precache_is_replaced_in_place(self) -> None:
        self.default_ini.write_text(DEFAULT_INI + "\n[D3DDrv.D3DRenderDevice]\nUseTrilinear=False\n"
                                    "UsePrecache=True\nUseVSync=False\n", encoding="ascii")
        installer.deploy(self.install)
        self.assertEqual(self.section(self.default_ini, "[D3DDrv.D3DRenderDevice]"),
                         ["UseTrilinear=False", "UsePrecache=False", "UseVSync=False"])

    def test_engine_keys_are_replaced_in_place(self) -> None:
        installer.deploy(self.install)
        engine = self.section(self.default_ini, "[Engine.Engine]")
        self.assertEqual(engine, ["GameRenderDevice=D3DDrv.D3DRenderDevice", "Language=int",
                                  "Console=HPArchipelago.APConsole",
                                  "DefaultGame=HPArchipelago.APGameInfo"])

    def test_other_sections_survive(self) -> None:
        installer.deploy(self.install)
        self.assertEqual(self.section(self.default_ini, "[Engine.GameInfo]"), ["bLowGore=True"])
        self.assertEqual(self.section(self.default_ini, "[ATI 3D Rage Pro]"), ["UseTrilinear=0"])

    def test_missing_engine_key_is_added_to_its_section(self) -> None:
        self.default_ini.write_text(DEFAULT_INI.replace("Console=HGame.HPConsole\n", ""),
                                    encoding="ascii")
        installer.deploy(self.install)
        engine = self.section(self.default_ini, "[Engine.Engine]")
        self.assertIn("Console=HPArchipelago.APConsole", engine)
        self.assertEqual(self.section(self.default_ini, "[Engine.GameInfo]"), ["bLowGore=True"])

    def test_deploy_is_idempotent(self) -> None:
        installer.deploy(self.install)
        first = self.default_ini.read_bytes()
        self.assertEqual(installer.deploy(self.install), [])
        self.assertEqual(self.default_ini.read_bytes(), first)

    def test_changed_channel_is_rewritten_once(self) -> None:
        installer.deploy(self.install)
        self.channel = str(self.user_dir / "Elsewhere")
        with mock.patch.object(installer, "channel_dir", return_value=Path(self.channel)):
            installer.deploy(self.install)
        self.assertEqual(self.section(self.default_ini, "[HPArchipelago.APIPCActor]"),
                         ["ChannelDir=" + self.channel])

    def test_backup_is_written_once(self) -> None:
        installer.deploy(self.install)
        self.default_ini.write_text("[Changed]\n", encoding="ascii")
        installer.deploy(self.install)
        backup = self.install / installer.BACKUP_DIR_NAME / "Default.ini"
        self.assertEqual(backup.read_text(encoding="ascii"), DEFAULT_INI)

    def test_utf16_ini_is_edited_in_its_own_encoding(self) -> None:
        self.default_ini.write_text(DEFAULT_INI, encoding="utf-16")
        installer.deploy(self.install)
        text = self.default_ini.read_text(encoding="utf-16")
        self.assertIn("DefaultGame=HPArchipelago.APGameInfo", text)

    def test_missing_default_ini_raises(self) -> None:
        self.default_ini.unlink()
        with self.assertRaises(FileNotFoundError):
            installer.deploy(self.install)

    def test_apworld_without_packaged_module_raises(self) -> None:
        with mock.patch.object(installer, "_packaged_module_bytes", return_value=None):
            with self.assertRaises(FileNotFoundError):
                installer.deploy(self.install)


class TestUserGameIni(InstallerCase):
    def setUp(self) -> None:
        super().setUp()
        self.game_ini = self.user_dir / "Game.ini"
        self.game_ini.write_text(GAME_INI, encoding="ascii")

    def test_game_ini_is_wired_in_place(self) -> None:
        log = installer.deploy(self.install)
        self.assertIn("Pointed the per-user Game.ini at the mod.", log)
        self.assertEqual(self.section(self.game_ini, "[Engine.Engine]"),
                         ["Console=HPArchipelago.APConsole",
                          "DefaultGame=HPArchipelago.APGameInfo"])
        self.assertEqual(self.section(self.game_ini, "[HPArchipelago.APIPCActor]"),
                         ["ChannelDir=" + self.channel])
        self.assertEqual(self.section(self.game_ini, "[D3DDrv.D3DRenderDevice]"), ["UsePrecache=False"])

    def test_player_settings_survive(self) -> None:
        installer.deploy(self.install)
        self.assertEqual(self.section(self.game_ini, "[WinDrv.WindowsClient]"),
                         ["WindowedViewportX=1024", "StartupFullscreen=False"])

    def test_game_ini_backup_is_kept(self) -> None:
        installer.deploy(self.install)
        backup = self.user_dir / installer.BACKUP_DIR_NAME / "Game.ini"
        self.assertEqual(backup.read_text(encoding="ascii"), GAME_INI)

    def test_game_ini_is_idempotent(self) -> None:
        installer.deploy(self.install)
        first = self.game_ini.read_bytes()
        self.assertEqual(installer.deploy(self.install), [])
        self.assertEqual(self.game_ini.read_bytes(), first)

    def test_missing_game_ini_is_fine(self) -> None:
        self.game_ini.unlink()
        installer.deploy(self.install)
        self.assertFalse(self.game_ini.exists())


class TestModIsCurrent(InstallerCase):
    def test_matching_install_is_current(self) -> None:
        installer.deploy(self.install)
        self.assertTrue(installer.mod_is_current(self.install))

    def test_matching_package_with_unwired_default_ini_is_stale(self) -> None:
        (self.system / "HPArchipelago.u").write_bytes(PACKAGE_BYTES)
        self.assertFalse(installer.mod_is_current(self.install))

    def test_matching_package_with_unwired_game_ini_is_stale(self) -> None:
        installer.deploy(self.install)
        (self.user_dir / "Game.ini").write_text(GAME_INI, encoding="ascii")
        self.assertFalse(installer.mod_is_current(self.install))

    def test_texture_precache_left_on_is_stale(self) -> None:
        installer.deploy(self.install)
        text = self.default_ini.read_text(encoding="latin-1")
        self.default_ini.write_text(text.replace("UsePrecache=False", "UsePrecache=True"), encoding="latin-1")
        self.assertFalse(installer.mod_is_current(self.install))

    def test_wired_game_ini_is_current(self) -> None:
        (self.user_dir / "Game.ini").write_text(GAME_INI, encoding="ascii")
        installer.deploy(self.install)
        self.assertTrue(installer.mod_is_current(self.install))

    def test_unreadable_ini_is_stale(self) -> None:
        installer.deploy(self.install)
        self.default_ini.write_bytes(b"\xff\xfe[")
        self.assertFalse(installer.mod_is_current(self.install))

    def test_missing_installed_package_is_stale(self) -> None:
        self.assertFalse(installer.mod_is_current(self.install))

    def test_different_installed_package_is_stale(self) -> None:
        (self.system / "HPArchipelago.u").write_bytes(b"older package")
        self.assertFalse(installer.mod_is_current(self.install))

    def test_apworld_without_packaged_module_is_current(self) -> None:
        with mock.patch.object(installer, "_packaged_module_bytes", return_value=None):
            self.assertTrue(installer.mod_is_current(self.install))


class TestLongChannelPath(InstallerCase):
    def test_overlong_channel_path_warns(self) -> None:
        long_path = "C:\\" + "x" * installer.MAX_CHANNEL_PATH_CHARS
        with mock.patch.object(installer, "_short_path", return_value=long_path):
            log = installer.deploy(self.install)
        self.assertTrue(any(line.startswith("WARNING: the game link folder") for line in log))

    def test_short_channel_path_does_not_warn(self) -> None:
        log = installer.deploy(self.install)
        self.assertFalse(any(line.startswith("WARNING") for line in log))


class TestShortPath(unittest.TestCase):
    def test_short_path_keeps_a_short_path(self) -> None:
        self.assertEqual(installer._short_path(Path("C:/AP")), str(Path("C:/AP")))


if __name__ == "__main__":
    unittest.main()
