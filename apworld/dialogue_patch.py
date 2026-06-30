"""Per-seed dialogue randomizer: binary patch of AllDialog.uax + the caption .ints.

The client applies this on Connected. The audio package and every caption .int
are patched with one shared permutation so the on-screen caption matches the
voice that plays:

  - AllDialog.uax: each dialogue USound export's serial pointer is repointed at a
    shuffled target's (the same mechanic the SFX patcher uses): no audio bytes
    move, names never change, file size is unchanged.
  - hpdialog.int / BumpDialog.int: each line's caption text is replaced by its
    target's text. Story and emote lines caption from hpdialog.int; the generic
    student bump lines caption from BumpDialog.int (HChar.uc localizes those from
    "BumpDialog", not "HPdialog"). Both files must be patched, or bump subtitles
    keep their original text while the voice is shuffled.

Audio is loaded by string id (baseDialog.uc / HChar.uc: DynamicLoadObject(
"AllDialog." $ id)) and the caption is looked up separately by that same id
(Localize("all", id, <file>)). Patching every source by the same permutation
keeps voice and caption in sync. In all_actors mode a line can be shuffled onto
one whose text lives in the other caption file, so a target's text is resolved
across all caption files. A line whose voiced target has no caption in the game
(match commentary, ambient bumps, alternate takes) shows none, as unmodified.

Two modes: 'within_actor' shuffles each speaker's lines among themselves (the
character keeps their own voice), 'all_actors' shuffles across every speaker. The
dialogue_pool BLACKLIST is excluded from both modes (kept as itself, never reused
as a target) so the Peeves trap-toast cackle still plays as a cackle. A sentinel
trailer in AllDialog.uax records (format, dialogue_seed, mode, table_hash) so
re-running the same seed and mode is a no-op, while a new seed, a mode switch, or
an apworld upgrade re-patches cleanly from the pristine .orig backups.

Pure standard library so it ships in the apworld and runs client-side.
"""

from __future__ import annotations

import hashlib
import os
import struct
from collections import namedtuple

try:
    from .dialogue_pool import ACTORS, BLACKLIST
    from .ue1_package import Package, PatchError, atomic_write, read_file, restore_one
except ImportError:  # standalone CLI use from the apworld directory
    from dialogue_pool import ACTORS, BLACKLIST
    from ue1_package import Package, PatchError, atomic_write, read_file, restore_one


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
    """Stable digest of the actor table (bucket membership/order) and the
    blacklist. Any change re-keys the trailer so an upgraded apworld re-patches.
    """
    h = hashlib.sha256()
    for actor in sorted(ACTORS):
        for name in ACTORS[actor]:
            h.update(f"{actor}|{name}\n".encode())
    for name in sorted(BLACKLIST):
        h.update(f"B|{name}\n".encode())
    return h.digest()[:16]


def compute_permutation(dialogue_seed: int, mode: str) -> dict[str, str]:
    """Seeded shuffle. 'all_actors' permutes every line across all speakers;
    'within_actor' permutes each speaker's lines only among themselves. A
    single-line bucket identity-maps. Keyed on the dialog id (export name).

    Blacklisted ids identity-map (excluded from the shuffle, so their audio is
    neither changed nor reused as a target): the Peeves trap-toast cackle always
    plays as itself, the way the SFX patcher protects its feedback cues.
    """
    import random

    rng = random.Random(dialogue_seed)
    blocked = {n.lower() for n in BLACKLIST}
    mapping: dict[str, str] = {}
    if mode == ALL_ACTORS:
        names = [n for actor in sorted(ACTORS) for n in ACTORS[actor]]
        groups = [names]
    else:
        groups = [ACTORS[actor] for actor in sorted(ACTORS)]
    for names in groups:
        shuffleable = [n for n in names if n.lower() not in blocked]
        targets = shuffleable[:]
        rng.shuffle(targets)
        for src, dst in zip(shuffleable, targets):
            mapping[src] = dst
        for n in names:
            if n.lower() in blocked:
                mapping[n] = n
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


# --- caption rebuild (the .int localization files) ---

def _parse_captions(pristine: bytes) -> dict[str, str]:
    """id(lower) -> caption value for one .int caption file (the text after '=')."""
    out = {}
    for line in pristine.decode("latin-1").splitlines():
        if "=" in line and not line.lstrip().startswith("["):
            key, _, val = line.partition("=")
            out[key.strip().lower()] = val
    return out


def _rebuild_text(pristine: bytes, perm: dict[str, str],
                  captions: dict[str, str]) -> bytes:
    """Rewrite one .int caption file so each line's caption is its permutation
    target's text. Line ordering, the [All] header, and CRLF endings are
    preserved; only the value after '=' changes, and only for keys the
    permutation moves (keys outside the pool pass through). The target's text is
    resolved from `captions`, which merges every caption file, so an all_actors
    target whose text lives in a different .int still resolves. A target with no
    caption anywhere yields an empty value, so a caption-less clip shows none.
    """
    out = []
    for line in pristine.decode("latin-1").splitlines(keepends=True):
        body = line.rstrip("\r\n")
        ending = line[len(body):]
        if "=" in body and not body.lstrip().startswith("["):
            key, _, _val = body.partition("=")
            dst = perm.get(key.strip().lower())
            if dst is not None:
                out.append(f"{key}={captions.get(dst, '')}{ending}")
                continue
        out.append(line)
    return "".join(out).encode("latin-1")


# --- file operations ---

def package_path(install_path: str) -> str:
    return os.path.join(install_path, "Sounds", "AllDialog.uax")


def caption_paths(install_path: str) -> list[str]:
    """The .int files carrying dialogue captions, each patched with the same
    permutation. hpdialog.int holds story and emote lines (baseDialog.uc localizes
    from "HPdialog"); BumpDialog.int holds the generic student bump lines (HChar.uc
    localizes those from "BumpDialog"). Both share the [All] section + key=value
    format. Order matters only for the few keys present in both files: a later
    file's text wins as the shuffle source.
    """
    system = os.path.join(install_path, "system")
    return [os.path.join(system, "hpdialog.int"),
            os.path.join(system, "BumpDialog.int")]


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


def _read_pristine(txt_path: str) -> tuple[bytes, bytes] | None:
    """(current, pristine) for one caption .int, seeding its .orig backup on the
    first run. None if the file is absent. The .int carries no trailer of its own,
    so the pristine .orig backup is the source of truth, like the audio package's.
    """
    if not os.path.exists(txt_path):
        return None
    orig_path = txt_path + ".orig"
    current = read_file(txt_path)
    if not os.path.exists(orig_path):
        atomic_write(orig_path, current, _TMP_PREFIX)  # first run: current is pristine
        return current, current
    return current, read_file(orig_path)


def _apply_captions(install_path: str, dialogue_seed: int, mode: str) -> str:
    """Patch every caption .int for (dialogue_seed, mode) with one shared
    permutation. Returns 'patched' if any file changed, 'unchanged', or 'no-file'
    (no caption .int present). Each line's new caption is its target's original
    text, looked up across all caption files (later file wins on a duplicate key)
    so an all_actors target whose text lives in a different .int still resolves.
    Each file is rebuilt from its own pristine .orig and compared for idempotency.
    """
    perm = {src.lower(): dst.lower() for src, dst in
            compute_permutation(dialogue_seed, mode).items()}
    loaded = {}
    for txt_path in caption_paths(install_path):
        pair = _read_pristine(txt_path)
        if pair is not None:
            loaded[txt_path] = pair
    if not loaded:
        return "no-file"
    captions: dict[str, str] = {}
    for _current, pristine in loaded.values():
        captions.update(_parse_captions(pristine))
    changed = False
    for txt_path, (current, pristine) in loaded.items():
        target = _rebuild_text(pristine, perm, captions)
        if current != target:
            atomic_write(txt_path, target, _TMP_PREFIX)
            changed = True
    return "patched" if changed else "unchanged"


def apply_patch(install_path: str, dialogue_seed: int, mode: str) -> str:
    """Patch the voice (AllDialog.uax) and the captions (hpdialog.int +
    BumpDialog.int) for (dialogue_seed, mode) with one shared permutation. Returns
    'patched' if any file changed, else 'unchanged'.
    """
    if mode not in _MODE_CODE:
        raise PatchError(f"unknown dialogue mode {mode!r}")
    audio = _apply_audio(install_path, dialogue_seed, mode)
    captions = _apply_captions(install_path, dialogue_seed, mode)
    return "patched" if "patched" in (audio, captions) else "unchanged"


def restore_original(install_path: str) -> str:
    """Restore AllDialog.uax and every caption .int (hpdialog.int, BumpDialog.int)
    from their .orig backups. Returns 'restored' if any changed, 'no-backup' if
    none was ever patched, else 'unchanged'.
    """
    results = [restore_one(package_path(install_path), _TMP_PREFIX)]
    results += [restore_one(p, _TMP_PREFIX) for p in caption_paths(install_path)]
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
