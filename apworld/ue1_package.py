"""Generic Unreal Engine 1 (v79) package reader plus the shared file helpers the
per-package patchers (sound_patch, dialogue_patch) build on.

Parses the header and name/import/export tables far enough to enumerate exports
and rewrite their serial pointers (mechanic A, verified in Phase 0): no object
bytes move and names never change, so a patch only repoints export pointers. The
atomic-write / backup helpers are here too because both patchers need the same
permission-denied handling. Pure standard library so it ships in the apworld and
runs client-side.
"""

from __future__ import annotations

import os
import struct
from dataclasses import dataclass


MAGIC = 0x9E2A83C1


class PatchError(Exception):
    """Raised for unrecoverable patch states; the client surfaces the message."""


# --- compact index ---

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


# --- package reader (header + export table; enough to repoint exports) ---

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
            raise PatchError(f"package has bad magic 0x{magic:08X}")
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
            # group_index is a fixed 32-bit int in v79, not a compact index.
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


# --- file operations ---

def read_file(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def safe_remove(path: str) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


DENIED_MSG = (
    "could not write to the Harry Potter install folder (permission denied). Close "
    "the game if it is running. If the install is under Program Files, close the "
    "Archipelago launcher and reopen it as administrator, then reconnect."
)


def atomic_write(path: str, data: bytes, tmp_prefix: str) -> None:
    # Open the temp file directly rather than via tempfile.mkstemp. On Windows a
    # denied folder (the usual non-elevated write under Program Files) makes
    # mkstemp spin TMP_MAX times: it retries every PermissionError that
    # os.access(W_OK) wrongly reports as writable, stalling this executor thread
    # for tens of seconds and freezing the window when shutdown joins it on exit.
    # A plain os.open surfaces the denial at once as the friendly admin message.
    tmp = os.path.join(os.path.dirname(path), tmp_prefix + os.urandom(8).hex() + ".tmp")
    flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_BINARY", 0)
    try:
        fd = os.open(tmp, flags, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    except PermissionError as e:
        safe_remove(tmp)
        raise PatchError(DENIED_MSG) from e
    except BaseException:
        safe_remove(tmp)
        raise


def restore_one(path: str, tmp_prefix: str) -> str:
    """Copy path.orig back over path. Returns 'restored', 'unchanged', or
    'no-backup' (never patched)."""
    orig_path = path + ".orig"
    if not os.path.exists(orig_path):
        return "no-backup"
    pristine = read_file(orig_path)
    if os.path.exists(path) and read_file(path) == pristine:
        return "unchanged"
    atomic_write(path, pristine, tmp_prefix)
    return "restored"
