"""Open castle map patch: level geometry the open castle game removes.

The open castle game changes a little of the compiled level geometry, which the
mod cannot change while the game runs. For each change listed below, the client
sets a surface flag on the matching surfaces of the level's compiled geometry in
the player's own map file, with a one-time .orig backup. The surfaces are found
in that file by the brush and the texture that produced them, so nothing from
the game ships with the patcher.

A compiled surface record (FBspSurf) is serialized as: texture (compact index),
polygon flags (uint32), base point, normal, texture U and V axes, light map and
brush polygon (six compact indices), pan U and V (two uint16), then the brush
actor that produced it (compact index).

Applied for open castle seeds; a vanilla seed restores the original file.

Pure standard library so it ships in the apworld and runs client-side.
"""

from __future__ import annotations

import os
import struct
from collections import namedtuple

from .ue1_package import (Package, PatchError, atomic_write, read_compact_index, read_file, restore_one,
                          write_compact_index)

_TMP_PREFIX = ".mappatch_"

# Polygon flags.
PF_INVISIBLE = 0x00000001

# One change: in map, the surfaces brush made with texture get flags added.
# surfaces is how many the stock map has; any other count leaves the map alone.
SurfaceChange = namedtuple("SurfaceChange", "map brush texture flags surfaces")

CHANGES = (
    # The vine over the Forbidden Forest gate on the Grounds.
    SurfaceChange("Grounds_hub.unr", "Brush154", "VineWall2_GH1", PF_INVISIBLE, 1),
)


def map_path(install_path: str, map_name: str) -> str:
    return os.path.join(install_path, "Maps", map_name)


def maps_touched() -> "list[str]":
    """The map files the patch changes, each once."""
    return sorted({change.map for change in CHANGES})


def _level_model(package: Package):
    """The level's compiled geometry: the largest Model export."""
    models = [e for e in package.exports if package.class_name(e) == "Model"]
    if not models:
        raise PatchError("map has no compiled geometry")
    return max(models, key=lambda e: e.serial_size)


def _export_ref(package: Package, name: str, class_name: str) -> "int | None":
    for index, export in enumerate(package.exports):
        if package.name_of(export) == name and package.class_name(export) == class_name:
            return index + 1
    return None


def _texture_refs(package: Package, name: str) -> "set[int]":
    refs = {index + 1 for index, export in enumerate(package.exports)
            if package.name_of(export) == name and package.class_name(export) == "Texture"}
    refs |= {-(index + 1) for index, name_index in enumerate(package.imports)
             if package.names[name_index] == name}
    return refs


def surface_flag_offsets(data: bytes, change: SurfaceChange) -> "list[int]":
    """File offsets of the polygon flags of every compiled surface brush made
    with texture, read from the map's own data. Empty when the map has no such
    brush or texture, as in a map that already differs from the stock one."""
    try:
        package = Package(data)
        brush = _export_ref(package, change.brush, "Brush")
        textures = _texture_refs(package, change.texture)
    except (struct.error, IndexError, ValueError) as exc:
        raise PatchError(f"{change.map} is damaged and cannot be read") from exc
    if brush is None or not textures:
        return []
    model = _level_model(package)
    start, end = model.serial_offset, model.serial_offset + model.serial_size
    found = []
    for texture in textures:
        needle = write_compact_index(texture)
        at = data.find(needle, start, end)
        while at >= 0:
            flags_at = at + len(needle)
            if _surface_actor(data, flags_at, end) == brush:
                found.append(flags_at)
            at = data.find(needle, at + 1, end)
    return sorted(found)


def _surface_actor(data: bytes, flags_at: int, end: int) -> "int | None":
    """The brush actor a surface record names, reading from its flags field, or
    None when the bytes there cannot be a surface record."""
    try:
        position = flags_at + 4
        for _ in range(6):
            _value, position = read_compact_index(data, position)
        position += 4
        actor, position = read_compact_index(data, position)
    except IndexError:
        return None
    return actor if position <= end else None


def _patched(pristine: bytes, map_name: str) -> bytes:
    out = bytearray(pristine)
    for change in CHANGES:
        if change.map != map_name:
            continue
        offsets = surface_flag_offsets(pristine, change)
        if len(offsets) != change.surfaces:
            continue
        for offset in offsets:
            flags, = struct.unpack_from("<I", out, offset)
            struct.pack_into("<I", out, offset, flags | change.flags)
    return bytes(out)


def apply_patch(install_path: str) -> str:
    """Patch every listed map from its pristine copy. Returns 'patched' if a
    file changed, 'unchanged' if every map was already patched or has nothing
    to patch, or 'no-file' when the install has none of the maps."""
    results = []
    for map_name in maps_touched():
        path = map_path(install_path, map_name)
        if not os.path.exists(path):
            results.append("no-file")
            continue
        current = read_file(path)
        orig_path = path + ".orig"
        pristine = read_file(orig_path) if os.path.exists(orig_path) else current
        target = _patched(pristine, map_name)
        if target == pristine or current == target:
            results.append("unchanged")
            continue
        if not os.path.exists(orig_path):
            atomic_write(orig_path, pristine, _TMP_PREFIX)
        atomic_write(path, target, _TMP_PREFIX)
        results.append("patched")
    if "patched" in results:
        return "patched"
    if all(result == "no-file" for result in results):
        return "no-file"
    return "unchanged"


def restore_original(install_path: str) -> str:
    """Put every patched map back from its .orig backup. Returns 'restored',
    'unchanged', or 'no-backup' when none was ever patched."""
    results = [restore_one(map_path(install_path, map_name), _TMP_PREFIX) for map_name in maps_touched()]
    if "restored" in results:
        return "restored"
    if all(result == "no-backup" for result in results):
        return "no-backup"
    return "unchanged"
