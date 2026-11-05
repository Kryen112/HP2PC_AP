"""One install folder serves both game modes. A host.yaml that still keeps a
folder per mode moves it into install_folder on load and drops the old keys."""

import unittest
from types import SimpleNamespace
from unittest import mock

from .. import Client, HP2Settings


def _load(values: dict) -> HP2Settings:
    group = HP2Settings()
    group.update(values)
    return group


class TestInstallFolderSetting(unittest.TestCase):
    def test_install_folder_is_read_as_is(self) -> None:
        group = _load({"install_folder": "C:/Games/HP2"})
        self.assertEqual(str(group.install_folder), "C:/Games/HP2")
        self.assertNotIn("vanilla_install_folder", list(group))

    def test_per_mode_folder_moves_into_install_folder(self) -> None:
        group = _load({"vanilla_install_folder": "C:/Games/HP2", "open_castle_install_folder": ""})
        self.assertEqual(str(group.install_folder), "C:/Games/HP2")
        self.assertEqual([key for key in group if key.endswith("install_folder")], ["install_folder"])
        self.assertTrue(group.changed)

    def test_open_castle_folder_moves_when_it_is_the_only_one(self) -> None:
        group = _load({"open_castle_install_folder": "D:/HP2"})
        self.assertEqual(str(group.install_folder), "D:/HP2")

    def test_vanilla_folder_wins_when_both_per_mode_folders_are_set(self) -> None:
        group = _load({"vanilla_install_folder": "C:/A", "open_castle_install_folder": "D:/B"})
        self.assertEqual(str(group.install_folder), "C:/A")

    def test_install_folder_wins_over_a_per_mode_folder(self) -> None:
        group = _load({"install_folder": "C:/Games/HP2", "vanilla_install_folder": "D:/Old"})
        self.assertEqual(str(group.install_folder), "C:/Games/HP2")
        self.assertNotIn("vanilla_install_folder", list(group))
        self.assertTrue(group.changed)

    def test_client_reads_the_one_folder_for_either_mode(self) -> None:
        group = _load({"install_folder": "C:/Games/HP2"})
        with mock.patch.object(Client, "HP2World", SimpleNamespace(settings=group)):
            self.assertEqual(Client._hp2_install_path(), "C:/Games/HP2")

    def test_blank_folder_reads_as_unset(self) -> None:
        with mock.patch.object(Client, "HP2World", SimpleNamespace(settings=_load({}))):
            self.assertIsNone(Client._hp2_install_path())
