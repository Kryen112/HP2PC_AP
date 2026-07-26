"""Contract tests for the mod installer's deploy step, against a throwaway
install tree. Default.ini continues past the EditPackages list into
graphics-adapter sections, so the anchored insertion (immediately after
EditPackages=M212Share, never end of file or end of section) is the
load-bearing behavior these pin, together with idempotence, the one-time
backups, and the in-place patching of the per-user override inis.
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

[Editor.EditorEngine]
EditPackages=Core
EditPackages=Engine
EditPackages=HPSounds
EditPackages=HPModels
EditPackages=HGame
EditPackages=M212Share

[Engine.GameInfo]
bLowGore=True

[ATI 3D Rage Pro]
UseTrilinear=0
"""

# A per-user HP.ini as the first game launch writes it: Default.ini's package
# list plus the player's own [Core.System] settings.
HP_INI = """[Editor.EditorEngine]
EditPackages=Core
EditPackages=Engine
EditPackages=HPSounds
EditPackages=HPModels
EditPackages=HGame
EditPackages=M212Share

[Core.System]
CacheRecordPath=../System/*.ucl
"""

GAME_INI = """[Engine.Engine]
DefaultGame=Engine.GameInfo

[WinDrv.WindowsClient]
WindowedViewportX=1024
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
        self.user_dir = root / "Documents" / "Harry - Coding Evolved"
        self.user_dir.mkdir(parents=True)
        packaged = root / "packaged" / "HPArchipelago.u"
        packaged.parent.mkdir()
        packaged.write_bytes(PACKAGE_BYTES)
        self._patches = [
            mock.patch.object(installer, "MOD_PACKAGE_DATA", packaged),
            mock.patch.object(installer, "_user_ini_dir",
                              return_value=self.user_dir),
        ]
        for patch in self._patches:
            patch.start()
        self.installed_package = self.system / "HPArchipelago.u"

    def tearDown(self) -> None:
        for patch in self._patches:
            patch.stop()
        self._tmp.cleanup()

    def default_ini_lines(self) -> "list[str]":
        return self.default_ini.read_text(encoding="ascii").splitlines()


class TestDeploy(InstallerCase):
    def test_deploy_wires_everything(self) -> None:
        installer.deploy(self.install)
        self.assertEqual(self.installed_package.read_bytes(), PACKAGE_BYTES)
        lines = self.default_ini_lines()
        self.assertIn("EditPackages=HPArchipelago", lines)
        self.assertIn("EditPackages=IpDrv", lines)
        self.assertIn(installer.DEFAULT_GAME_ARCHIPELAGO, lines)
        self.assertNotIn("DefaultGame=Engine.GameInfo", lines)

    def test_edit_packages_land_after_the_anchor(self) -> None:
        # Not end of file and not end of section: the entries go immediately
        # after the last stock entry, before the sections that follow.
        installer.deploy(self.install)
        lines = self.default_ini_lines()
        anchor = lines.index(installer.EDIT_PACKAGES_ANCHOR)
        self.assertEqual(lines[anchor + 1], "EditPackages=IpDrv")
        self.assertEqual(lines[anchor + 2], "EditPackages=HPArchipelago")

    def test_player_settings_survive(self) -> None:
        installer.deploy(self.install)
        lines = self.default_ini_lines()
        self.assertIn("Console=HGame.HPConsole", lines)
        self.assertIn("Language=int", lines)
        self.assertIn("UseTrilinear=0", lines)

    def test_deploy_is_idempotent(self) -> None:
        installer.deploy(self.install)
        first = self.default_ini.read_bytes()
        log = installer.deploy(self.install)
        self.assertEqual(log, [])
        self.assertEqual(self.default_ini.read_bytes(), first)
        lines = self.default_ini_lines()
        self.assertEqual(lines.count("EditPackages=HPArchipelago"), 1)
        self.assertEqual(lines.count("EditPackages=IpDrv"), 1)

    def test_stray_mod_entries_are_normalized(self) -> None:
        # A hand-patched install can carry the entries in the wrong spot (for
        # example appended at end of file, inside a graphics-adapter section);
        # deploy moves them to the anchored position.
        self.default_ini.write_text(
            DEFAULT_INI + "EditPackages=HPArchipelago\n", encoding="ascii")
        installer.deploy(self.install)
        lines = self.default_ini_lines()
        self.assertEqual(lines.count("EditPackages=HPArchipelago"), 1)
        anchor = lines.index(installer.EDIT_PACKAGES_ANCHOR)
        self.assertEqual(lines[anchor + 2], "EditPackages=HPArchipelago")
        self.assertNotEqual(lines[-1], "EditPackages=HPArchipelago")

    def test_backup_is_written_once(self) -> None:
        backup = self.install / installer.BACKUP_DIR_NAME / "Default.ini"
        installer.deploy(self.install)
        self.assertEqual(backup.read_text(encoding="ascii"), DEFAULT_INI)
        installer.deploy(self.install)
        self.assertEqual(backup.read_text(encoding="ascii"), DEFAULT_INI)

    def test_utf16_ini_is_edited_in_its_own_encoding(self) -> None:
        self.default_ini.write_text(DEFAULT_INI, encoding="utf-16")
        installer.deploy(self.install)
        raw = self.default_ini.read_bytes()
        self.assertEqual(raw[:2], b"\xff\xfe")
        text = raw.decode("utf-16")
        self.assertIn("EditPackages=HPArchipelago", text)
        self.assertIn(installer.DEFAULT_GAME_ARCHIPELAGO, text)

    def test_missing_anchor_raises(self) -> None:
        self.default_ini.write_text(
            DEFAULT_INI.replace("EditPackages=M212Share\n", ""), encoding="ascii")
        with self.assertRaises(ValueError):
            installer.deploy(self.install)

    def test_missing_default_ini_raises(self) -> None:
        self.default_ini.unlink()
        with self.assertRaises(FileNotFoundError):
            installer.deploy(self.install)

    def test_apworld_without_packaged_module_raises(self) -> None:
        with mock.patch.object(installer, "_packaged_module_bytes",
                               return_value=None):
            with self.assertRaises(FileNotFoundError):
                installer.deploy(self.install)


class TestUserInis(InstallerCase):
    def test_missing_user_dir_is_fine(self) -> None:
        with mock.patch.object(installer, "_user_ini_dir",
                               return_value=self.user_dir / "absent"):
            installer.deploy(self.install)
        self.assertEqual(self.installed_package.read_bytes(), PACKAGE_BYTES)

    def test_hp_ini_is_wired_in_place(self) -> None:
        hp_ini = self.user_dir / "HP.ini"
        hp_ini.write_text(HP_INI, encoding="ascii")
        installer.deploy(self.install)
        lines = hp_ini.read_text(encoding="ascii").splitlines()
        anchor = lines.index(installer.EDIT_PACKAGES_ANCHOR)
        self.assertEqual(lines[anchor + 1], "EditPackages=IpDrv")
        self.assertEqual(lines[anchor + 2], "EditPackages=HPArchipelago")
        # The player's own settings survive, and a backup exists.
        self.assertIn("CacheRecordPath=../System/*.ucl", lines)
        self.assertEqual(
            (self.user_dir / installer.BACKUP_DIR_NAME / "HP.ini")
            .read_text(encoding="ascii"), HP_INI)

    def test_game_ini_default_game_is_pointed_at_the_mod(self) -> None:
        game_ini = self.user_dir / "Game.ini"
        game_ini.write_text(GAME_INI, encoding="ascii")
        installer.deploy(self.install)
        lines = game_ini.read_text(encoding="ascii").splitlines()
        self.assertIn(installer.DEFAULT_GAME_ARCHIPELAGO, lines)
        self.assertNotIn("DefaultGame=Engine.GameInfo", lines)
        self.assertIn("WindowedViewportX=1024", lines)

    def test_game_ini_without_the_key_is_left_alone(self) -> None:
        # An absent DefaultGame falls through to Default.ini, so there is
        # nothing to fix and the file is not rewritten.
        game_ini = self.user_dir / "Game.ini"
        content = "[WinDrv.WindowsClient]\nWindowedViewportX=1024\n"
        game_ini.write_text(content, encoding="ascii")
        installer.deploy(self.install)
        self.assertEqual(game_ini.read_text(encoding="ascii"), content)

    def test_foreign_hp_ini_package_list_warns(self) -> None:
        # A package list without the M212Share anchor cannot be patched
        # mechanically, yet it shadows Default.ini; the player is told.
        hp_ini = self.user_dir / "HP.ini"
        content = "[Editor.EditorEngine]\nEditPackages=Core\nEditPackages=Engine\n"
        hp_ini.write_text(content, encoding="ascii")
        log = installer.deploy(self.install)
        self.assertTrue(any("WARNING" in line and "HP.ini" in line for line in log))
        self.assertEqual(hp_ini.read_text(encoding="ascii"), content)

    def test_user_inis_are_idempotent(self) -> None:
        (self.user_dir / "HP.ini").write_text(HP_INI, encoding="ascii")
        (self.user_dir / "Game.ini").write_text(GAME_INI, encoding="ascii")
        installer.deploy(self.install)
        first_hp = (self.user_dir / "HP.ini").read_bytes()
        first_game = (self.user_dir / "Game.ini").read_bytes()
        log = installer.deploy(self.install)
        self.assertEqual(log, [])
        self.assertEqual((self.user_dir / "HP.ini").read_bytes(), first_hp)
        self.assertEqual((self.user_dir / "Game.ini").read_bytes(), first_game)


class TestModIsCurrent(InstallerCase):
    def test_matching_install_is_current(self) -> None:
        installer.deploy(self.install)
        self.assertTrue(installer.mod_is_current(self.install))

    def test_missing_installed_package_is_stale(self) -> None:
        self.assertFalse(installer.mod_is_current(self.install))

    def test_different_installed_package_is_stale(self) -> None:
        installer.deploy(self.install)
        self.installed_package.write_bytes(b"a locally compiled package")
        self.assertFalse(installer.mod_is_current(self.install))

    def test_apworld_without_packaged_module_is_current(self) -> None:
        with mock.patch.object(installer, "_packaged_module_bytes",
                               return_value=None):
            self.assertTrue(installer.mod_is_current(self.install))


if __name__ == "__main__":
    unittest.main()
