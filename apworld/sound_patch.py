"""Per-seed SFX randomizer: binary patch of the game's HPSounds.u.

The client applies this on Connected. It repoints each USound export's serial
pointer at a shuffled target's (mechanic A, verified in Phase 0): no audio bytes
move, object names never change, and the file size is unchanged. A sentinel
trailer appended after the export table records (format, sound_seed, table_hash)
so re-running for the same seed and mode is a no-op and an apworld upgrade, seed
change, or mode switch re-patches cleanly from the pristine .orig backup.

Two modes: 'on' randomizes everything but the always-on BLACKLIST feedback cues;
'no_footsteps' additionally leaves the FOOTSTEPS set (Harry's footsteps) alone, so
they are neither changed nor reused as a target. The mode rides in table_hash, not
a trailer field, so the trailer format is unchanged and a file patched by an older
build is still recognised as patched and re-patched from .orig.

Pure standard library so it ships in the apworld and runs client-side.
"""

from __future__ import annotations

import hashlib
import os
import struct
from collections import namedtuple

try:
    from .sound_pool import BLACKLIST, FOOTSTEPS, LONG, MEDIUM, SHORT
    from .ue1_package import Package, PatchError, atomic_write, read_file
except ImportError:  # standalone CLI use from the apworld directory
    from sound_pool import BLACKLIST, FOOTSTEPS, LONG, MEDIUM, SHORT
    from ue1_package import Package, PatchError, atomic_write, read_file


_TMP_PREFIX = ".hpsounds_"

TRAILER_MAGIC = b"HP2SNDR\x00"
TRAILER_FORMAT = 1
_TRAILER = struct.Struct("<8sBI16s")  # magic, format, sound_seed, table_hash[:16]
TRAILER_SIZE = _TRAILER.size

Trailer = namedtuple("Trailer", "format sound_seed table_hash")

# Shuffle modes. ON randomizes everything but the BLACKLIST; NO_FOOTSTEPS also
# leaves Harry's footsteps (the FOOTSTEPS set) alone.
ON = "on"
NO_FOOTSTEPS = "no_footsteps"
_MODES = (ON, NO_FOOTSTEPS)


# --- permutation + trailer ---

def table_hash(mode: str) -> bytes:
    """Stable digest of the shuffle inputs (band membership/order, blacklist,
    footstep set, and mode). Any change re-keys the trailer so a mode switch or an
    upgraded apworld re-patches.
    """
    h = hashlib.sha256()
    for tag, band in (("S", SHORT), ("M", MEDIUM), ("L", LONG)):
        for group, name in band:
            h.update(f"{tag}|{group}|{name}\n".encode())
    for group, name in sorted(BLACKLIST):
        h.update(f"B|{group}|{name}\n".encode())
    for group, name in sorted(FOOTSTEPS):
        h.update(f"F|{group}|{name}\n".encode())
    h.update(f"M|{mode}\n".encode())
    return h.digest()[:16]


def compute_permutation(sound_seed: int, mode: str) -> dict[tuple[str, str], tuple[str, str]]:
    """Seeded shuffle within each duration band. Blocked pairs identity-map
    (excluded from the shuffle, so their audio is neither changed nor reused): the
    BLACKLIST always, plus the FOOTSTEPS set when mode is 'no_footsteps'.
    """
    import random

    rng = random.Random(sound_seed)
    blocked = {(g.lower(), n.lower()) for g, n in BLACKLIST}
    if mode == NO_FOOTSTEPS:
        blocked |= {(g.lower(), n.lower()) for g, n in FOOTSTEPS}
    mapping: dict[tuple[str, str], tuple[str, str]] = {}
    for band in (SHORT, MEDIUM, LONG):
        shuffleable = [gn for gn in band if (gn[0].lower(), gn[1].lower()) not in blocked]
        targets = shuffleable[:]
        rng.shuffle(targets)
        for src, dst in zip(shuffleable, targets):
            mapping[src] = dst
        for gn in band:
            if (gn[0].lower(), gn[1].lower()) in blocked:
                mapping[gn] = gn
    return mapping


def parse_trailer(data: bytes) -> Trailer | None:
    if len(data) < TRAILER_SIZE:
        return None
    magic, fmt, seed, thash = _TRAILER.unpack(data[-TRAILER_SIZE:])
    if magic != TRAILER_MAGIC:
        return None
    return Trailer(fmt, seed, thash)


def _build_patched(pristine: bytes, sound_seed: int, mode: str) -> bytes:
    pkg = Package(pristine)
    sounds = {(pkg.group_of(e).lower(), pkg.name_of(e).lower()): e
              for e in pkg.exports if pkg.class_name(e) == "Sound"}
    original = {k: (e.serial_offset, e.serial_size) for k, e in sounds.items()}
    for src, dst in compute_permutation(sound_seed, mode).items():
        se = sounds.get((src[0].lower(), src[1].lower()))
        dptr = original.get((dst[0].lower(), dst[1].lower()))
        if se is None or dptr is None:
            continue  # name not present in this build; leave it alone
        se.serial_offset, se.serial_size = dptr
    table = bytearray()
    for e in pkg.exports:
        table += pkg.encode_export(e)
    trailer = _TRAILER.pack(TRAILER_MAGIC, TRAILER_FORMAT, sound_seed, table_hash(mode))
    return pkg.data[:pkg.export_offset] + bytes(table) + trailer


# --- file operations ---

def package_path(install_path: str) -> str:
    return os.path.join(install_path, "system", "HPSounds.u")


def apply_patch(install_path: str, sound_seed: int, mode: str) -> str:
    """Patch HPSounds.u for (sound_seed, mode). Returns 'patched' or 'unchanged'.

    A pristine working file (no trailer) seeds/refreshes the .orig backup; a
    patched file is always re-patched from .orig so seeds never compound.
    """
    if mode not in _MODES:
        raise PatchError(f"unknown sound mode {mode!r}")
    pkg_path = package_path(install_path)
    orig_path = pkg_path + ".orig"
    current = read_file(pkg_path)
    trailer = parse_trailer(current)
    digest = table_hash(mode)

    if (trailer and trailer.format == TRAILER_FORMAT
            and trailer.sound_seed == sound_seed and trailer.table_hash == digest):
        return "unchanged"

    if trailer is None:
        if not os.path.exists(orig_path) or read_file(orig_path) != current:
            atomic_write(orig_path, current, _TMP_PREFIX)
        pristine = current
    else:
        if not os.path.exists(orig_path):
            raise PatchError(
                "HPSounds.u is patched but HPSounds.u.orig backup is missing. "
                "Reinstall the game's sound package to recover the original."
            )
        pristine = read_file(orig_path)
        if parse_trailer(pristine) is not None:
            raise PatchError("HPSounds.u.orig is not a pristine backup.")

    atomic_write(pkg_path, _build_patched(pristine, sound_seed, mode), _TMP_PREFIX)
    return "patched"


def restore_original(install_path: str) -> str:
    """Copy the pristine .orig back over HPSounds.u. Returns 'restored',
    'unchanged', or 'no-backup' (install was never patched).
    """
    pkg_path = package_path(install_path)
    orig_path = pkg_path + ".orig"
    if not os.path.exists(orig_path):
        return "no-backup"
    pristine = read_file(orig_path)
    if os.path.exists(pkg_path) and read_file(pkg_path) == pristine:
        return "unchanged"
    atomic_write(pkg_path, pristine, _TMP_PREFIX)
    return "restored"


if __name__ == "__main__":
    import sys

    if len(sys.argv) >= 5 and sys.argv[1] == "apply":
        print(apply_patch(sys.argv[2], int(sys.argv[3]), sys.argv[4]))
    elif len(sys.argv) >= 3 and sys.argv[1] == "restore":
        print(restore_original(sys.argv[2]))
    else:
        print("usage: sound_patch.py apply <install_path> <sound_seed> "
              "<on|no_footsteps>\n"
              "       sound_patch.py restore <install_path>")
