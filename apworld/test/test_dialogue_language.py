"""The dialogue randomizer patches the files the game actually plays. A
non-English disc install (Language=dut) ships its voices as
Sounds\\AllDialog.DUT_uax, which the engine loads in place of AllDialog.uax, and
reads captions from HpDialog.dut / BumpDialog.dut; an English install uses
AllDialog.uax and the .int captions. The language comes from the per-user
Game.ini when it sets one (it overrides Default.ini, as in the engine). File
names match without regard to case, as the disc spells them inconsistently. A
restore undoes every language's patch, so switching language never strands a
patched file."""
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from .. import dialogue_patch


def make_install(root: Path, language: "str | None", files: "list[str]") -> Path:
    install = root / "HP2"
    (install / "system").mkdir(parents=True)
    (install / "Sounds").mkdir()
    if language is not None:
        write_language(install / "system" / "Default.ini", language)
    for name in files:
        (install / name).write_bytes(b"")
    return install


def write_language(path: Path, language: str) -> None:
    path.write_text(f"[Engine.Engine]\nGameRenderDevice=D3DDrv.D3DRenderDevice\nLanguage={language}\n\n"
                    f"[Core.System]\nPaths=../Sounds/*.uax\n", encoding="latin-1")


class LanguageCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.user_dir = self.root / "Documents" / "Harry Potter II"
        self.user_dir.mkdir(parents=True)
        self._patch = mock.patch.object(dialogue_patch, "_user_ini_dir", return_value=self.user_dir)
        self._patch.start()

    def tearDown(self) -> None:
        self._patch.stop()
        self._tmp.cleanup()

    def names(self, paths: "list[str]") -> "list[str]":
        return [os.path.basename(path) for path in paths]


class TestDialogueLanguage(LanguageCase):
    def test_dutch_install_patches_its_own_files(self) -> None:
        install = make_install(self.root, "dut", [
            "Sounds/AllDialog.DUT_uax", "system/HpDialog.dut", "system/hpdialog.int",
            "system/BumpDialog.dut", "system/BumpDialog.int"])
        self.assertEqual(dialogue_patch.install_language(str(install)), "dut")
        self.assertEqual(os.path.basename(dialogue_patch.package_path(str(install))), "AllDialog.DUT_uax")
        self.assertEqual(self.names(dialogue_patch.caption_paths(str(install))), ["HpDialog.dut", "BumpDialog.dut"])

    def test_english_install_keeps_the_int_files(self) -> None:
        install = make_install(self.root, "int", [
            "Sounds/AllDialog.uax", "system/hpdialog.int", "system/BumpDialog.int"])
        self.assertEqual(os.path.basename(dialogue_patch.package_path(str(install))), "AllDialog.uax")
        self.assertEqual(self.names(dialogue_patch.caption_paths(str(install))), ["hpdialog.int", "BumpDialog.int"])

    def test_missing_localized_file_falls_back_to_english(self) -> None:
        install = make_install(self.root, "dut", [
            "Sounds/AllDialog.uax", "system/hpdialog.int", "system/BumpDialog.dut", "system/BumpDialog.int"])
        self.assertEqual(os.path.basename(dialogue_patch.package_path(str(install))), "AllDialog.uax")
        self.assertEqual(self.names(dialogue_patch.caption_paths(str(install))), ["hpdialog.int", "BumpDialog.dut"])

    def test_no_ini_means_english(self) -> None:
        install = make_install(self.root, None, ["Sounds/AllDialog.uax"])
        self.assertEqual(dialogue_patch.install_language(str(install)), dialogue_patch.ENGLISH)

    def test_names_match_without_regard_to_case(self) -> None:
        install = make_install(self.root, "DUT", ["Sounds/alldialog.dut_uax", "system/hpdialog.DUT"])
        self.assertEqual(os.path.basename(dialogue_patch.package_path(str(install))), "alldialog.dut_uax")
        self.assertEqual(self.names(dialogue_patch.caption_paths(str(install)))[0], "hpdialog.DUT")

    def test_language_key_is_read_from_the_engine_section_only(self) -> None:
        install = make_install(self.root, "int", ["Sounds/AllDialog.uax"])
        ini = install / "system" / "Default.ini"
        ini.write_text("[Other]\nLanguage=fre\n\n" + ini.read_text(encoding="latin-1"), encoding="latin-1")
        self.assertEqual(dialogue_patch.install_language(str(install)), "int")

    def test_user_game_ini_overrides_default_ini(self) -> None:
        install = make_install(self.root, "int", ["Sounds/AllDialog.uax"])
        write_language(self.user_dir / "Game.ini", "dut")
        self.assertEqual(dialogue_patch.install_language(str(install)), "dut")

    def test_unfindable_user_folder_falls_back_to_default_ini(self) -> None:
        install = make_install(self.root, "dut", [])
        for error in (ValueError("not inside a prefix"), OSError("unreadable")):
            with self.subTest(error=type(error).__name__), \
                    mock.patch.object(dialogue_patch, "_user_ini_dir", side_effect=error):
                self.assertEqual(dialogue_patch.install_language(str(install)), "dut")

    def test_spaces_around_the_key_are_accepted(self) -> None:
        install = make_install(self.root, None, [])
        (install / "system" / "Default.ini").write_text("[Engine.Engine]\nLanguage = dut\n", encoding="latin-1")
        self.assertEqual(dialogue_patch.install_language(str(install)), "dut")


class TestLocalizedCaptionRoundTrip(LanguageCase):
    """Captions patch and restore byte for byte on a localized install with one
    localized caption file and one English fallback."""

    def setUp(self) -> None:
        super().setUp()
        moved = [source for source, target in dialogue_patch.compute_permutation(7, "all_actors").items()
                 if source.lower() != target.lower()][:6]
        self.assertTrue(moved)
        self.install = make_install(self.root, "dut", [])
        system = self.install / "system"
        self.dutch = system / "HpDialog.dut"
        self.english = system / "BumpDialog.int"
        self.dutch.write_bytes(("[All]\r\n" + "".join(f"{key}=Regel {i}\r\n" for i, key in enumerate(moved[:3])))
                               .encode("latin-1"))
        self.english.write_bytes(("[All]\r\n" + "".join(f"{key}=Line {i}\r\n" for i, key in enumerate(moved[3:])))
                                 .encode("latin-1"))
        self.originals = {path: path.read_bytes() for path in (self.dutch, self.english)}

    def test_apply_then_restore_is_byte_identical(self) -> None:
        self.assertEqual(self.names(dialogue_patch.caption_paths(str(self.install))),
                         ["HpDialog.dut", "BumpDialog.int"])
        self.assertEqual(dialogue_patch._apply_captions(str(self.install), 7, "all_actors"), "patched")
        self.assertNotEqual(self.dutch.read_bytes(), self.originals[self.dutch])
        self.assertTrue((self.install / "system" / "HpDialog.dut.orig").is_file())
        self.assertEqual(dialogue_patch.restore_original(str(self.install)), "restored")
        for path, original in self.originals.items():
            self.assertEqual(path.read_bytes(), original)

    def test_restore_after_a_language_change_undoes_the_old_language(self) -> None:
        dialogue_patch._apply_captions(str(self.install), 7, "all_actors")
        write_language(self.install / "system" / "Default.ini", "int")
        self.assertNotIn("HpDialog.dut", self.names(dialogue_patch.caption_paths(str(self.install))))
        self.assertEqual(dialogue_patch.restore_original(str(self.install)), "restored")
        self.assertEqual(self.dutch.read_bytes(), self.originals[self.dutch])


if __name__ == "__main__":
    unittest.main()
