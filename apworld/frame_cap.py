"""Frame rate cap: hold the game at 60 frames per second.

Above about 120 frames per second the game itself speeds up, and uncapped it
runs as fast as the graphics card allows, so its speed follows the frame rate.
The engine's main loop already sleeps to whatever rate its tick rate function
returns, but for a single player game that function returns zero, which means
no limit. The patch changes one instruction at the end of that function in the
player's own system\\Engine.dll: instead of loading the zero constant, it
loads a whole number the engine already holds that equals 60. Four bytes
change, the instruction keeps its length and its relocated address, and a
one-time .orig backup restores the original.

The bytes are checked before anything is written, so an engine build that
differs, or one put in place after the backup, is left alone.

Pure standard library so it ships in the apworld and runs client-side.
"""

from __future__ import annotations

import os

from .ue1_package import atomic_write, read_file

_TMP_PREFIX = ".framecap_"

# File offset of the instruction that loads the tick rate a single player game
# returns, the instruction before and after the patch (the trailing two bytes
# are the unchanged top of the absolute address), and the frame rate it sets.
CAP_OFFSET = 0xA9883
ORIGINAL = bytes.fromhex("d90598454710")  # fld dword ptr [0x10474598] (0.0)
PATCHED = bytes.fromhex("df0552464710")   # fild word ptr [0x10474652] (60)
FRAME_RATE = 60

# What bringing the engine to a setting does. CAP and UNCAP write the file,
# NONE means it already matches, UNKNOWN that the engine is not the one the
# patch is for (or was swapped after the backup), NO_FILE that there is no
# engine, NO_BACKUP that an uncapped engine is wanted but there is no original
# to put back.
CAP = "cap"
UNCAP = "uncap"
NONE = "none"
UNKNOWN = "unknown"
NO_FILE = "no-file"
NO_BACKUP = "no-backup"


def engine_path(install_path: str) -> str:
    return os.path.join(install_path, "system", "Engine.dll")


def _instruction(data: bytes) -> bytes:
    return data[CAP_OFFSET:CAP_OFFSET + len(ORIGINAL)]


def _capped(data: bytes) -> bytes:
    return data[:CAP_OFFSET] + PATCHED + data[CAP_OFFSET + len(PATCHED):]


def _plan(install_path: str, capped: bool) -> "tuple[str, bytes]":
    """What bringing the engine to the setting does, and the bytes to write
    for CAP and UNCAP. Reads only."""
    path = engine_path(install_path)
    if not os.path.exists(path):
        return NO_FILE, b""
    current = read_file(path)
    orig_path = path + ".orig"
    if not os.path.exists(orig_path):
        if _instruction(current) == ORIGINAL:
            return (CAP, _capped(current)) if capped else (NONE, b"")
        if _instruction(current) == PATCHED:
            # Capped by hand: right as it is, or nothing to put back.
            return (NONE, b"") if capped else (NO_BACKUP, b"")
        return UNKNOWN, b""
    pristine = read_file(orig_path)
    if _instruction(pristine) != ORIGINAL:
        return UNKNOWN, b""
    target = _capped(pristine)
    if current not in (pristine, target):
        return UNKNOWN, b""
    if capped:
        return (NONE, b"") if current == target else (CAP, target)
    return (NONE, b"") if current == pristine else (UNCAP, pristine)


def change_pending(install_path: str, capped: bool) -> bool:
    """Whether bringing the engine to the setting would change the file."""
    return _plan(install_path, capped)[0] in (CAP, UNCAP)


def apply_cap(install_path: str) -> str:
    """Cap the engine. Returns 'patched' when the file changed, 'unchanged'
    when it already was capped, 'unknown' when the engine is not the one the
    patch is for, or 'no-file'."""
    action, data = _plan(install_path, True)
    if action != CAP:
        return {NONE: "unchanged", NO_FILE: "no-file"}.get(action, "unknown")
    path = engine_path(install_path)
    if not os.path.exists(path + ".orig"):
        # The checked engine: the capped bytes with the original instruction.
        original = data[:CAP_OFFSET] + ORIGINAL + data[CAP_OFFSET + len(ORIGINAL):]
        atomic_write(path + ".orig", original, _TMP_PREFIX)
    atomic_write(path, data, _TMP_PREFIX)
    return "patched"


def remove_cap(install_path: str) -> str:
    """Put the original engine back. Returns 'restored', 'unchanged',
    'no-backup' when there is no original to put back, or 'unknown' when the
    engine was swapped after the backup."""
    action, data = _plan(install_path, False)
    if action != UNCAP:
        return {NONE: "unchanged", NO_FILE: "no-backup", NO_BACKUP: "no-backup"}.get(action, "unknown")
    atomic_write(engine_path(install_path), data, _TMP_PREFIX)
    return "restored"
