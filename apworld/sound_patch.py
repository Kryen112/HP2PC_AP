"""Per-seed SFX randomizer: binary patch of the game's HPSounds.u.

The client applies this on Connected. It repoints each USound export's serial
pointer at a shuffled target's (mechanic A, verified in Phase 0): no audio bytes
move, object names never change, and the file size is unchanged. A sentinel
trailer appended after the export table records (format, sound_seed, table_hash)
so re-running for the same seed is a no-op and an apworld upgrade or seed change
re-patches cleanly from the pristine .orig backup.

Pure standard library so it ships in the apworld and runs client-side.
"""

from __future__ import annotations

import hashlib
import os
import struct
from collections import namedtuple
from dataclasses import dataclass

try:
    from .sound_pool import BLACKLIST, LONG, MEDIUM, SHORT
except ImportError:  # standalone CLI use from the apworld directory
    from sound_pool import BLACKLIST, LONG, MEDIUM, SHORT


MAGIC = 0x9E2A83C1

TRAILER_MAGIC = b"HP2SNDR\x00"
TRAILER_FORMAT = 1
_TRAILER = struct.Struct("<8sBI16s")  # magic, format, sound_seed, table_hash[:16]
TRAILER_SIZE = _TRAILER.size

Trailer = namedtuple("Trailer", "format sound_seed table_hash")


class PatchError(Exception):
    """Raised for unrecoverable patch states; the client surfaces the message."""


# --- UE1 package reader (header + export table; enough to repoint exports) ---

def read_compact_index(buf: bytes, pos: int) -> tuple[int, int]:
    b0 = buf[pos]
    pos += 1
    negative = b0 & 0x80
    value = b0 & 0x3F
    if b0 & 0x40:
        shift = 6
        while True:
            b = buf[pos]
            pos += 1
            value |= (b & 0x7F) << shift
            shift += 7
            if not (b & 0x80):
                break
    return (-value if negative else value), pos


def write_compact_index(value: int) -> bytes:
    negative = value < 0
    v = -value if negative else value
    out = bytearray()
    b0 = v & 0x3F
    v >>= 6
    if negative:
        b0 |= 0x80
    if v:
        b0 |= 0x40
    out.append(b0)
    while v:
        b = v & 0x7F
        v >>= 7
        if v:
            b |= 0x80
        out.append(b)
    return bytes(out)


@dataclass
class ExportEntry:
    class_index: int
    super_index: int
    group_index: int
    name_index: int
    flags: int
    serial_size: int
    serial_offset: int


class Package:
    def __init__(self, data: bytes):
        self.data = data
        magic, = struct.unpack_from("<I", data, 0)
        if magic != MAGIC:
            raise PatchError(f"HPSounds.u has bad magic 0x{magic:08X}")
        self.version, self.licensee = struct.unpack_from("<HH", data, 4)
        (self.name_count, self.name_offset, self.export_count, self.export_offset,
         self.import_count, self.import_offset) = struct.unpack_from("<6i", data, 12)
        self._parse_names()
        self._parse_imports()
        self._parse_exports()

    def _parse_names(self) -> None:
        d = self.data
        pos = self.name_offset
        self.names: list[str] = []
        for _ in range(self.name_count):
            if self.version < 64:
                end = d.index(0, pos)
                name = d[pos:end].decode("latin-1")
                pos = end + 1
            else:
                length, pos = read_compact_index(d, pos)
                name = d[pos:pos + length - 1].decode("latin-1")
                pos += length
            pos += 4
            self.names.append(name)

    def _parse_imports(self) -> None:
        d = self.data
        pos = self.import_offset
        self.imports = []
        for _ in range(self.import_count):
            _cp, pos = read_compact_index(d, pos)
            _cn, pos = read_compact_index(d, pos)
            pos += 4
            name, pos = read_compact_index(d, pos)
            self.imports.append(name)

    def _parse_exports(self) -> None:
        d = self.data
        pos = self.export_offset
        self.exports: list[ExportEntry] = []
        for _ in range(self.export_count):
            cls, pos = read_compact_index(d, pos)
            sup, pos = read_compact_index(d, pos)
            grp, = struct.unpack_from("<i", d, pos)
            pos += 4
            name, pos = read_compact_index(d, pos)
            flags, = struct.unpack_from("<I", d, pos)
            pos += 4
            size, pos = read_compact_index(d, pos)
            offset = 0
            if size > 0:
                offset, pos = read_compact_index(d, pos)
            self.exports.append(ExportEntry(cls, sup, grp, name, flags, size, offset))

    def encode_export(self, e: ExportEntry) -> bytes:
        out = bytearray()
        out += write_compact_index(e.class_index)
        out += write_compact_index(e.super_index)
        out += struct.pack("<i", e.group_index)
        out += write_compact_index(e.name_index)
        out += struct.pack("<I", e.flags)
        out += write_compact_index(e.serial_size)
        if e.serial_size > 0:
            out += write_compact_index(e.serial_offset)
        return bytes(out)

    def _ref_name(self, ref: int) -> str:
        if ref > 0:
            return self.names[self.exports[ref - 1].name_index]
        if ref < 0:
            return self.names[self.imports[-ref - 1]]
        return ""

    def class_name(self, e: ExportEntry) -> str:
        return "Class" if e.class_index == 0 else self._ref_name(e.class_index)

    def name_of(self, e: ExportEntry) -> str:
        return self.names[e.name_index]

    def group_of(self, e: ExportEntry) -> str:
        return self._ref_name(e.group_index)


# --- permutation + trailer ---

def table_hash() -> bytes:
    """Stable digest of the shuffle inputs (band membership/order + blacklist).
    Any change re-keys the trailer so an upgraded apworld re-patches.
    """
    h = hashlib.sha256()
    for tag, band in (("S", SHORT), ("M", MEDIUM), ("L", LONG)):
        for group, name in band:
            h.update(f"{tag}|{group}|{name}\n".encode())
    for group, name in sorted(BLACKLIST):
        h.update(f"B|{group}|{name}\n".encode())
    return h.digest()[:16]


def compute_permutation(sound_seed: int) -> dict[tuple[str, str], tuple[str, str]]:
    """Seeded shuffle within each duration band. Blacklisted pairs identity-map
    (excluded from the shuffle, so their audio is neither changed nor reused).
    """
    import random

    rng = random.Random(sound_seed)
    blocked = {(g.lower(), n.lower()) for g, n in BLACKLIST}
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


def _build_patched(pristine: bytes, sound_seed: int) -> bytes:
    pkg = Package(pristine)
    sounds = {(pkg.group_of(e).lower(), pkg.name_of(e).lower()): e
              for e in pkg.exports if pkg.class_name(e) == "Sound"}
    original = {k: (e.serial_offset, e.serial_size) for k, e in sounds.items()}
    for src, dst in compute_permutation(sound_seed).items():
        se = sounds.get((src[0].lower(), src[1].lower()))
        dptr = original.get((dst[0].lower(), dst[1].lower()))
        if se is None or dptr is None:
            continue  # name not present in this build; leave it alone
        se.serial_offset, se.serial_size = dptr
    table = bytearray()
    for e in pkg.exports:
        table += pkg.encode_export(e)
    trailer = _TRAILER.pack(TRAILER_MAGIC, TRAILER_FORMAT, sound_seed, table_hash())
    return pkg.data[:pkg.export_offset] + bytes(table) + trailer


# --- file operations ---

def package_path(install_path: str) -> str:
    return os.path.join(install_path, "system", "HPSounds.u")


def _read(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


_DENIED_MSG = (
    "could not write to the Harry Potter install folder (permission denied). Close "
    "the game if it is running. If the install is under Program Files, close the "
    "Archipelago launcher and reopen it as administrator, then reconnect."
)


def _atomic_write(path: str, data: bytes) -> None:
    # Open the temp file directly rather than via tempfile.mkstemp. On Windows a
    # denied folder (the usual non-elevated write under Program Files) makes
    # mkstemp spin TMP_MAX times: it retries every PermissionError that
    # os.access(W_OK) wrongly reports as writable, stalling this executor thread
    # for tens of seconds and freezing the window when shutdown joins it on exit.
    # A plain os.open surfaces the denial at once as the friendly admin message.
    tmp = os.path.join(os.path.dirname(path), ".hpsounds_" + os.urandom(8).hex() + ".tmp")
    flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_BINARY", 0)
    try:
        fd = os.open(tmp, flags, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    except PermissionError as e:
        _safe_remove(tmp)
        raise PatchError(_DENIED_MSG) from e
    except BaseException:
        _safe_remove(tmp)
        raise


def _safe_remove(path: str) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


def apply_patch(install_path: str, sound_seed: int) -> str:
    """Patch HPSounds.u for sound_seed. Returns 'patched' or 'unchanged'.

    A pristine working file (no trailer) seeds/refreshes the .orig backup; a
    patched file is always re-patched from .orig so seeds never compound.
    """
    pkg_path = package_path(install_path)
    orig_path = pkg_path + ".orig"
    current = _read(pkg_path)
    trailer = parse_trailer(current)
    digest = table_hash()

    if (trailer and trailer.format == TRAILER_FORMAT
            and trailer.sound_seed == sound_seed and trailer.table_hash == digest):
        return "unchanged"

    if trailer is None:
        if not os.path.exists(orig_path) or _read(orig_path) != current:
            _atomic_write(orig_path, current)
        pristine = current
    else:
        if not os.path.exists(orig_path):
            raise PatchError(
                "HPSounds.u is patched but HPSounds.u.orig backup is missing. "
                "Reinstall the game's sound package to recover the original."
            )
        pristine = _read(orig_path)
        if parse_trailer(pristine) is not None:
            raise PatchError("HPSounds.u.orig is not a pristine backup.")

    _atomic_write(pkg_path, _build_patched(pristine, sound_seed))
    return "patched"


def restore_original(install_path: str) -> str:
    """Copy the pristine .orig back over HPSounds.u. Returns 'restored',
    'unchanged', or 'no-backup' (install was never patched).
    """
    pkg_path = package_path(install_path)
    orig_path = pkg_path + ".orig"
    if not os.path.exists(orig_path):
        return "no-backup"
    pristine = _read(orig_path)
    if os.path.exists(pkg_path) and _read(pkg_path) == pristine:
        return "unchanged"
    _atomic_write(pkg_path, pristine)
    return "restored"


if __name__ == "__main__":
    import sys

    if len(sys.argv) >= 3 and sys.argv[1] == "apply":
        print(apply_patch(sys.argv[2], int(sys.argv[3])))
    elif len(sys.argv) >= 3 and sys.argv[1] == "restore":
        print(restore_original(sys.argv[2]))
    else:
        print("usage: sound_patch.py apply <install_path> <sound_seed>\n"
              "       sound_patch.py restore <install_path>")
