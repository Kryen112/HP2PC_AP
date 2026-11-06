"""The open castle map patch: it finds the listed surfaces in a map by brush and
texture, flags only those, keeps a pristine backup, and restores it for vanilla
seeds. The maps here are small synthetic packages, never game data."""

import asyncio
import os
import shutil
import struct
import tempfile
import unittest
from unittest import mock

from .. import Client, map_patch
from ..Client import HP2Context
from ..map_patch import PF_INVISIBLE, SurfaceChange
from ..ue1_package import MAGIC, PatchError, write_compact_index

MAP = "Grounds_hub.unr"
CHANGE = SurfaceChange(MAP, "Brush154", "VineWall2_GH1", PF_INVISIBLE, 1)
STOCK_FLAGS = 0x128


def _name(text: str) -> bytes:
    raw = text.encode("latin-1") + b"\0"
    return write_compact_index(len(raw)) + raw + struct.pack("<I", 0)


def _surface(texture: int, flags: int, actor: int) -> bytes:
    out = write_compact_index(texture) + struct.pack("<I", flags)
    for value in (5, 300, 0, 7, -1, 70000):
        out += write_compact_index(value)
    return out + struct.pack("<HH", 0, 0) + write_compact_index(actor)


def _package(brush_name: str = "Brush154", texture_name: str = "VineWall2_GH1") -> "tuple[bytes, int]":
    """A map with two brushes, the vine texture as an import, a large level model
    and a smaller decoy model. Returns the bytes and the vine surface's flags
    offset."""
    names = ["None", "Engine", "Class", "Model", "Brush", "Texture", texture_name, brush_name, "Brush3",
             "Model1", "Model2"]
    index = {name: number for number, name in enumerate(names)}
    # Imports: -1 the vine texture, -2 class Model, -3 class Brush.
    imports = [("Engine", "Texture", texture_name), ("Engine", "Class", "Model"), ("Engine", "Class", "Brush")]
    vine_brush, other_brush = 1, 2
    vine_texture = -1
    level_model = (
        b"\x81\x81\x81"
        + _surface(vine_texture, STOCK_FLAGS, other_brush)
        + _surface(0, STOCK_FLAGS, vine_brush)
    )
    vine_at_in_model = len(level_model) + len(write_compact_index(vine_texture))
    level_model += _surface(vine_texture, STOCK_FLAGS, vine_brush) + bytes(64)
    decoy_model = _surface(vine_texture, STOCK_FLAGS, vine_brush)

    header_size = 64
    name_table = b"".join(_name(name) for name in names)
    import_table = b"".join(
        write_compact_index(index[package]) + write_compact_index(index[class_name]) + struct.pack("<i", 0)
        + write_compact_index(index[object_name])
        for package, class_name, object_name in imports)
    name_offset = header_size
    import_offset = name_offset + len(name_table)
    level_offset = import_offset + len(import_table)
    decoy_offset = level_offset + len(level_model)
    export_offset = decoy_offset + len(decoy_model)
    exports = [(-3, brush_name, 0, 0), (-3, "Brush3", 0, 0), (-2, "Model1", len(level_model), level_offset),
               (-2, "Model2", len(decoy_model), decoy_offset)]
    export_table = b""
    for class_ref, name, size, offset in exports:
        export_table += write_compact_index(class_ref) + write_compact_index(0) + struct.pack("<i", 0)
        export_table += write_compact_index(index[name]) + struct.pack("<I", 0) + write_compact_index(size)
        if size:
            export_table += write_compact_index(offset)
    header = struct.pack("<IHHI6i", MAGIC, 79, 0, 0, len(names), name_offset, len(exports), export_offset,
                         len(imports), import_offset)
    header += bytes(header_size - len(header))
    data = header + name_table + import_table + level_model + decoy_model + export_table
    return data, level_offset + vine_at_in_model


def _flags(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


class TestSurfaceSearch(unittest.TestCase):
    def test_finds_only_the_brush_surface_with_the_texture_in_the_level_model(self) -> None:
        data, vine_at = _package()
        self.assertEqual(map_patch.surface_flag_offsets(data, CHANGE), [vine_at])

    def test_map_without_the_brush_has_nothing_to_patch(self) -> None:
        data, _ = _package(brush_name="Brush999")
        self.assertEqual(map_patch.surface_flag_offsets(data, CHANGE), [])

    def test_map_without_the_texture_has_nothing_to_patch(self) -> None:
        data, _ = _package(texture_name="OtherWall")
        self.assertEqual(map_patch.surface_flag_offsets(data, CHANGE), [])


class _InstallCase(unittest.TestCase):
    def setUp(self) -> None:
        self.install = tempfile.mkdtemp(prefix="hp2_map_patch_")
        self.addCleanup(shutil.rmtree, self.install, True)
        os.mkdir(os.path.join(self.install, "Maps"))
        self.path = map_patch.map_path(self.install, MAP)

    def write_map(self, data: bytes) -> None:
        with open(self.path, "wb") as f:
            f.write(data)

    def read_map(self, suffix: str = "") -> bytes:
        with open(self.path + suffix, "rb") as f:
            return f.read()


@mock.patch.object(map_patch, "CHANGES", (CHANGE,))
class TestApplyAndRestore(_InstallCase):
    def test_apply_flags_only_the_vine_and_keeps_a_pristine_backup(self) -> None:
        data, vine_at = _package()
        self.write_map(data)
        self.assertEqual(map_patch.apply_patch(self.install), "patched")
        patched = self.read_map()
        self.assertEqual(_flags(patched, vine_at), STOCK_FLAGS | PF_INVISIBLE)
        self.assertEqual(patched[:vine_at] + patched[vine_at + 4:], data[:vine_at] + data[vine_at + 4:])
        self.assertEqual(self.read_map(".orig"), data)

    def test_apply_twice_changes_nothing(self) -> None:
        data, _ = _package()
        self.write_map(data)
        map_patch.apply_patch(self.install)
        patched = self.read_map()
        self.assertEqual(map_patch.apply_patch(self.install), "unchanged")
        self.assertEqual(self.read_map(), patched)

    def test_apply_works_from_the_backup_when_the_map_was_replaced(self) -> None:
        data, vine_at = _package()
        self.write_map(data)
        map_patch.apply_patch(self.install)
        self.write_map(b"replaced")
        self.assertEqual(map_patch.apply_patch(self.install), "patched")
        self.assertEqual(_flags(self.read_map(), vine_at), STOCK_FLAGS | PF_INVISIBLE)

    def test_restore_puts_the_original_back(self) -> None:
        data, _ = _package()
        self.write_map(data)
        map_patch.apply_patch(self.install)
        self.assertEqual(map_patch.restore_original(self.install), "restored")
        self.assertEqual(self.read_map(), data)
        self.assertEqual(map_patch.restore_original(self.install), "unchanged")

    def test_map_with_nothing_to_patch_is_left_alone(self) -> None:
        data, _ = _package(brush_name="Brush999")
        self.write_map(data)
        self.assertEqual(map_patch.apply_patch(self.install), "unchanged")
        self.assertEqual(self.read_map(), data)
        self.assertFalse(os.path.exists(self.path + ".orig"))

    def test_missing_map_and_missing_backup(self) -> None:
        self.assertEqual(map_patch.apply_patch(self.install), "no-file")
        self.assertEqual(map_patch.restore_original(self.install), "no-backup")

    def test_bad_package_raises_a_patch_error(self) -> None:
        self.write_map(b"\0" * 64)
        with self.assertRaises(PatchError):
            map_patch.apply_patch(self.install)

    def test_truncated_package_raises_a_patch_error(self) -> None:
        data, _ = _package()
        self.write_map(data[:80])
        with self.assertRaises(PatchError):
            map_patch.apply_patch(self.install)

    def test_unexpected_surface_count_leaves_the_map_alone(self) -> None:
        data, _ = _package()
        self.write_map(data)
        with mock.patch.object(map_patch, "CHANGES", (CHANGE._replace(surfaces=2),)):
            self.assertEqual(map_patch.apply_patch(self.install), "unchanged")
        self.assertEqual(self.read_map(), data)
        self.assertFalse(os.path.exists(self.path + ".orig"))

    def test_backup_with_nothing_to_patch_never_overwrites_the_map(self) -> None:
        backup, _ = _package(brush_name="Brush999")
        self.write_map(b"current")
        with open(self.path + ".orig", "wb") as f:
            f.write(backup)
        self.assertEqual(map_patch.apply_patch(self.install), "unchanged")
        self.assertEqual(self.read_map(), b"current")


class TestClientMapPatch(_InstallCase):
    def run_client(self, sd: dict, install) -> None:
        asyncio.run(HP2Context._apply_map_patch(mock.Mock(), sd, install))

    def test_open_castle_seed_applies_and_vanilla_seed_restores(self) -> None:
        with mock.patch.object(map_patch, "apply_patch", return_value="patched") as apply, \
                mock.patch.object(map_patch, "restore_original", return_value="restored") as restore, \
                self.assertNoLogs("Client", level="INFO"), \
                self.assertLogs("HP2Client", level="INFO") as logs:
            self.run_client({"game_mode": "open_castle"}, self.install)
            apply.assert_called_once_with(self.install)
            restore.assert_not_called()
            self.run_client({"game_mode": "vanilla"}, self.install)
            restore.assert_called_once_with(self.install)
        self.assertEqual(len(logs.output), 2)

    def test_unset_install_touches_nothing(self) -> None:
        with mock.patch.object(Client, "_hp2_install_path", return_value=None), \
                mock.patch.object(map_patch, "apply_patch") as apply:
            self.run_client({"game_mode": "open_castle"}, None)
            apply.assert_not_called()

    def test_unset_install_falls_back_to_the_configured_folder(self) -> None:
        with mock.patch.object(Client, "_hp2_install_path", return_value=self.install) as configured, \
                mock.patch.object(map_patch, "apply_patch", return_value="unchanged") as apply:
            self.run_client({"game_mode": "open_castle"}, None)
            configured.assert_called_once_with()
            apply.assert_called_once_with(self.install)

    def test_folder_without_maps_touches_nothing(self) -> None:
        with mock.patch.object(map_patch, "apply_patch") as apply:
            self.run_client({"game_mode": "open_castle"}, os.path.join(self.install, "missing"))
            apply.assert_not_called()

    def test_unexpected_error_is_reported_not_raised(self) -> None:
        with mock.patch.object(map_patch, "apply_patch", side_effect=ValueError("broken")):
            with self.assertLogs("Client", level="ERROR") as logs:
                self.run_client({"game_mode": "open_castle"}, self.install)
        self.assertIn("map patch crashed", logs.output[0])

    def test_blocked_write_is_reported_not_raised(self) -> None:
        with mock.patch.object(map_patch, "apply_patch", return_value="patched"), \
                mock.patch.object(Client.asyncio, "wait_for", side_effect=asyncio.TimeoutError):
            with self.assertLogs("Client", level="ERROR") as logs:
                self.run_client({"game_mode": "open_castle"}, self.install)
        self.assertIn("looks blocked", logs.output[0])

    def test_patch_error_is_reported_not_raised(self) -> None:
        with mock.patch.object(map_patch, "apply_patch", side_effect=PatchError("denied")):
            with self.assertLogs("Client", level="ERROR") as logs:
                self.run_client({"game_mode": "open_castle"}, self.install)
        self.assertIn("denied", logs.output[0])
