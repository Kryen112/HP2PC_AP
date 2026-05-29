"""Per-seed dialogue randomizer: binary patch of AllDialog.uax + hpdialog.int.

The client applies this on Connected. Two files are patched with one shared
permutation so the on-screen caption matches the voice that plays:

  - AllDialog.uax: each dialogue USound export's serial pointer is repointed at a
    shuffled target's (the same mechanic the SFX patcher uses): no audio bytes
    move, names never change, file size is unchanged.
  - hpdialog.int: the caption text for each line is replaced by its target's text.

Lines are loaded by string id (baseDialog.uc: DynamicLoadObject("AllDialog." $
id)) and captions are looked up separately by that same id (Localize("all", id,
"HPdialog")). Patching both by the same permutation keeps voice and caption in
sync. A line whose voiced target has no caption in the game (match commentary,
ambient bumps, alternate takes) shows none, as in the unmodified game.

Two modes: 'within_actor' shuffles each speaker's lines among themselves (the
character keeps their own voice), 'all_actors' shuffles across every speaker. A
sentinel trailer in AllDialog.uax records (format, dialogue_seed, mode,
table_hash) so re-running the same seed and mode is a no-op, while a new seed, a
mode switch, or an apworld upgrade re-patches cleanly from the pristine .orig
backups.

Pure standard library so it ships in the apworld and runs client-side.
"""

from __future__ import annotations

import hashlib
import os
import struct
from collections import namedtuple

try:
    from .dialogue_pool import ACTORS
    from .ue1_package import Package, PatchError, atomic_write, read_file
except ImportError:  # standalone CLI use from the apworld directory
    from dialogue_pool import ACTORS
    from ue1_package import Package, PatchError, atomic_write, read_file


_TMP_PREFIX = ".alldialog_"

TRAILER_MAGIC = b"HP2DLGR\x00"
TRAILER_FORMAT = 1
_TRAILER = struct.Struct("<8sBIB16s")  # magic, format, dialogue_seed, mode, table_hash[:16]
TRAILER_SIZE = _TRAILER.size

Trailer = namedtuple("Trailer", "format dialogue_seed mode table_hash")

# Mode <-> trailer code. WITHIN keeps each speaker's voice; ALL goes cross-actor.
WITHIN_ACTOR = "within_actor"
ALL_ACTORS = "all_actors"
_MODE_CODE = {WITHIN_ACTOR: 1, ALL_ACTORS: 2}


# --- permutation + trailer ---

def table_hash() -> bytes:
    """Stable digest of the actor table (bucket membership/order). Any change
    re-keys the trailer so an upgraded apworld re-patches.
    """
    h = hashlib.sha256()
    for actor in sorted(ACTORS):
        for name in ACTORS[actor]:
            h.update(f"{actor}|{name}\n".encode())
    return h.digest()[:16]


def compute_permutation(dialogue_seed: int, mode: str) -> dict[str, str]:
    """Seeded shuffle. 'all_actors' permutes every line across all speakers;
    'within_actor' permutes each speaker's lines only among themselves. A
    single-line bucket identity-maps. Keyed on the dialog id (export name).
    """
    import random

    rng = random.Random(dialogue_seed)
    mapping: dict[str, str] = {}
    if mode == ALL_ACTORS:
        names = [n for actor in sorted(ACTORS) for n in ACTORS[actor]]
        groups = [names]
    else:
        groups = [ACTORS[actor] for actor in sorted(ACTORS)]
    for names in groups:
        targets = names[:]
        rng.shuffle(targets)
        for src, dst in zip(names, targets):
            mapping[src] = dst
    return mapping


def parse_trailer(data: bytes) -> Trailer | None:
    if len(data) < TRAILER_SIZE:
        return None
    magic, fmt, seed, mode, thash = _TRAILER.unpack(data[-TRAILER_SIZE:])
    if magic != TRAILER_MAGIC:
        return None
    return Trailer(fmt, seed, mode, thash)


def _build_patched(pristine: bytes, dialogue_seed: int, mode: str) -> bytes:
    pkg = Package(pristine)
    sounds = {pkg.name_of(e).lower(): e
              for e in pkg.exports if pkg.class_name(e) == "Sound"}
    original = {k: (e.serial_offset, e.serial_size) for k, e in sounds.items()}
    for src, dst in compute_permutation(dialogue_seed, mode).items():
        se = sounds.get(src.lower())
        dptr = original.get(dst.lower())
        if se is None or dptr is None:
            continue  # name not present in this build; leave it alone
        se.serial_offset, se.serial_size = dptr
    table = bytearray()
    for e in pkg.exports:
        table += pkg.encode_export(e)
    trailer = _TRAILER.pack(TRAILER_MAGIC, TRAILER_FORMAT, dialogue_seed,
                            _MODE_CODE[mode], table_hash())
    return pkg.data[:pkg.export_offset] + bytes(table) + trailer


# --- caption rebuild (hpdialog.int) ---

def _rebuild_text(pristine: bytes, dialogue_seed: int, mode: str) -> bytes:
    """Rewrite hpdialog.int so each line's caption is its permutation target's
    text. The line ordering, the [All] header, and CRLF endings are preserved;
    only the value after '=' changes, and only for keys that the permutation
    moves (text-only keys with no audio pass through). A target with no caption
    yields an empty value, so a line voiced by a caption-less clip shows none.
    """
    text = pristine.decode("latin-1")
    orig = {}
    for line in text.splitlines():
        if "=" in line and not line.lstrip().startswith("["):
            key, _, val = line.partition("=")
            orig[key.strip().lower()] = val
    perm = {src.lower(): dst.lower() for src, dst in
            compute_permutation(dialogue_seed, mode).items()}

    out = []
    for line in text.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        ending = line[len(body):]
        if "=" in body and not body.lstrip().startswith("["):
            key, _, _val = body.partition("=")
            dst = perm.get(key.strip().lower())
            if dst is not None:
                out.append(f"{key}={orig.get(dst, '')}{ending}")
                continue
        out.append(line)
    return "".join(out).encode("latin-1")


# --- file operations ---

def package_path(install_path: str) -> str:
    return os.path.join(install_path, "Sounds", "AllDialog.uax")


def text_path(install_path: str) -> str:
    return os.path.join(install_path, "system", "hpdialog.int")


def _apply_audio(install_path: str, dialogue_seed: int, mode: str) -> str:
    """Patch AllDialog.uax for (dialogue_seed, mode). Returns 'patched' or
    'unchanged'. A pristine working file (no trailer) seeds/refreshes the .orig
    backup; a patched file is always re-patched from .orig so seeds never compound.
    """
    pkg_path = package_path(install_path)
    orig_path = pkg_path + ".orig"
    current = read_file(pkg_path)
    trailer = parse_trailer(current)
    digest = table_hash()

    if (trailer and trailer.format == TRAILER_FORMAT
            and trailer.dialogue_seed == dialogue_seed
            and trailer.mode == _MODE_CODE[mode] and trailer.table_hash == digest):
        return "unchanged"

    if trailer is None:
        if not os.path.exists(orig_path) or read_file(orig_path) != current:
            atomic_write(orig_path, current, _TMP_PREFIX)
        pristine = current
    else:
        if not os.path.exists(orig_path):
            raise PatchError(
                "AllDialog.uax is patched but AllDialog.uax.orig backup is missing. "
                "Reinstall the game's dialogue package to recover the original."
            )
        pristine = read_file(orig_path)
        if parse_trailer(pristine) is not None:
            raise PatchError("AllDialog.uax.orig is not a pristine backup.")

    atomic_write(pkg_path, _build_patched(pristine, dialogue_seed, mode), _TMP_PREFIX)
    return "patched"


def _apply_text(install_path: str, dialogue_seed: int, mode: str) -> str:
    """Patch hpdialog.int captions for (dialogue_seed, mode). Returns 'patched',
    'unchanged', or 'no-file' (the install has no hpdialog.int). The .int has no
    trailer of its own, so the pristine .orig backup is the source of truth and the
    target is rebuilt from it and compared for idempotency.
    """
    txt_path = text_path(install_path)
    if not os.path.exists(txt_path):
        return "no-file"
    orig_path = txt_path + ".orig"
    current = read_file(txt_path)
    if not os.path.exists(orig_path):
        atomic_write(orig_path, current, _TMP_PREFIX)  # first run: current is pristine
        pristine = current
    else:
        pristine = read_file(orig_path)
    target = _rebuild_text(pristine, dialogue_seed, mode)
    if current == target:
        return "unchanged"
    atomic_write(txt_path, target, _TMP_PREFIX)
    return "patched"


def apply_patch(install_path: str, dialogue_seed: int, mode: str) -> str:
    """Patch the voice (AllDialog.uax) and the captions (hpdialog.int) for
    (dialogue_seed, mode) with one shared permutation. Returns 'patched' if either
    file changed, else 'unchanged'.
    """
    if mode not in _MODE_CODE:
        raise PatchError(f"unknown dialogue mode {mode!r}")
    audio = _apply_audio(install_path, dialogue_seed, mode)
    text = _apply_text(install_path, dialogue_seed, mode)
    return "patched" if "patched" in (audio, text) else "unchanged"


def _restore_one(path: str) -> str:
    """Copy path.orig back over path. Returns 'restored', 'unchanged', or
    'no-backup' (never patched)."""
    orig_path = path + ".orig"
    if not os.path.exists(orig_path):
        return "no-backup"
    pristine = read_file(orig_path)
    if os.path.exists(path) and read_file(path) == pristine:
        return "unchanged"
    atomic_write(path, pristine, _TMP_PREFIX)
    return "restored"


def restore_original(install_path: str) -> str:
    """Restore both AllDialog.uax and hpdialog.int from their .orig backups.
    Returns 'restored' if either changed, 'no-backup' if neither was ever patched,
    else 'unchanged'.
    """
    results = (_restore_one(package_path(install_path)),
               _restore_one(text_path(install_path)))
    if "restored" in results:
        return "restored"
    if all(r == "no-backup" for r in results):
        return "no-backup"
    return "unchanged"


if __name__ == "__main__":
    import sys

    if len(sys.argv) >= 5 and sys.argv[1] == "apply":
        print(apply_patch(sys.argv[2], int(sys.argv[3]), sys.argv[4]))
    elif len(sys.argv) >= 3 and sys.argv[1] == "restore":
        print(restore_original(sys.argv[2]))
    else:
        print("usage: dialogue_patch.py apply <install_path> <dialogue_seed> "
              "<within_actor|all_actors>\n"
              "       dialogue_patch.py restore <install_path>")
