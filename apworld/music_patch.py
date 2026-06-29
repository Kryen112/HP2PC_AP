"""Per-seed music randomizer: on-disk swap of the game's Music/*.ogg files.

The music tracks are loose ogg files referenced by bare basename, both by
NewMusicTrigger.Song and by native PlayMusic / cutscene `music X.ogg` commands.
Swapping a track's file content for a shuffled target's therefore covers every
reference, including the native call sites the old runtime NewMusicTrigger
rewrite could not reach (cutscenes, spell-lesson stingers, menu music). The
shuffle is within two buckets (MUSIC_POOL long-form tracks, JINGLE_POOL short
cues) so a jingle stays a jingle.

Originals are backed up once into Music/.hp2_backup, patched files are written
from that backup (never compounded), and a marker.json there records
(format, music_seed, pool_hash) for idempotent re-apply and clean re-shuffle.

Pure standard library so it ships in the apworld and runs client-side.
"""

from __future__ import annotations

import hashlib
import json
import os

try:
    from .music_pool import JINGLE_POOL, MUSIC_POOL
    from .ue1_package import DENIED_MSG, PatchError, atomic_write, safe_remove
except ImportError:  # standalone use from the apworld directory
    from music_pool import JINGLE_POOL, MUSIC_POOL
    from ue1_package import DENIED_MSG, PatchError, atomic_write, safe_remove

MARKER_FORMAT = 1
_MARKER_NAME = "marker.json"
_BACKUP_DIRNAME = ".hp2_backup"
# atomic_write temp-file prefix, named like the sibling patchers' _TMP_PREFIX.
_TMP_PREFIX = ".hpmus_"


def music_dir(install_path: str) -> str:
    return os.path.join(install_path, "Music")


def _backup_dir(install_path: str) -> str:
    return os.path.join(music_dir(install_path), _BACKUP_DIRNAME)


def _marker_path(install_path: str) -> str:
    return os.path.join(_backup_dir(install_path), _MARKER_NAME)


def _ogg(directory: str, name: str) -> str:
    return os.path.join(directory, name + ".ogg")


def pool_hash() -> str:
    """Stable digest of the shuffle inputs (bucket membership/order). A pool edit
    re-keys the marker so an upgraded apworld re-shuffles cleanly."""
    h = hashlib.sha256()
    for tag, pool in (("M", MUSIC_POOL), ("J", JINGLE_POOL)):
        for name in pool:
            h.update(f"{tag}|{name}\n".encode())
    return h.hexdigest()[:32]


def compute_permutation(music_seed: int) -> dict[str, str]:
    """Seeded shuffle within each pool. Jingles only swap with jingles."""
    import random

    rng = random.Random(music_seed)
    mapping: dict[str, str] = {}
    for pool in (MUSIC_POOL, JINGLE_POOL):
        targets = list(pool)
        rng.shuffle(targets)
        for src, dst in zip(pool, targets):
            mapping[src] = dst
    return mapping


def _read_marker(install_path: str):
    try:
        with open(_marker_path(install_path), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _present_names(mdir: str) -> list[str]:
    return [n for n in (MUSIC_POOL + JINGLE_POOL) if os.path.exists(_ogg(mdir, n))]


def apply_patch(install_path: str, music_seed: int) -> str:
    """Swap each track's content for its shuffled target's. Returns 'patched' or
    'unchanged'. A pristine Music folder (no marker) seeds the backup; a patched
    one is re-patched from the backup so seeds never compound."""
    mdir = music_dir(install_path)
    if not os.path.isdir(mdir):
        raise PatchError(f"no Music folder at {mdir}")
    marker = _read_marker(install_path)
    digest = pool_hash()
    if (marker and marker.get("format") == MARKER_FORMAT
            and marker.get("music_seed") == music_seed and marker.get("pool_hash") == digest):
        return "unchanged"

    bdir = _backup_dir(install_path)
    try:
        os.makedirs(bdir, exist_ok=True)
    except PermissionError as e:
        raise PatchError(DENIED_MSG) from e
    present = _present_names(mdir)
    if marker is None:
        for name in present:  # pristine working files seed/refresh the backup
            with open(_ogg(mdir, name), "rb") as f:
                atomic_write(_ogg(bdir, name), f.read(), _TMP_PREFIX)
    else:
        # A marker means the backup is already seeded from pristine files; trust
        # it (re-patch reads from it, never from the possibly-patched working
        # files) and only verify it is complete.
        missing = [n for n in present if not os.path.exists(_ogg(bdir, n))]
        if missing:
            raise PatchError(
                "music backup is incomplete; reinstall the Music folder to recover the originals."
            )

    permutation = compute_permutation(music_seed)
    for name in present:
        source = _ogg(bdir, permutation.get(name, name))
        if not os.path.exists(source):
            continue  # target absent in this build; leave the track alone
        with open(source, "rb") as f:
            atomic_write(_ogg(mdir, name), f.read(), _TMP_PREFIX)

    with open(_marker_path(install_path), "w", encoding="utf-8") as f:
        json.dump({"format": MARKER_FORMAT, "music_seed": music_seed, "pool_hash": digest}, f)
    return "patched"


def restore_original(install_path: str) -> str:
    """Copy backed-up originals back over the Music files. Returns 'restored',
    'unchanged', or 'no-backup' (the folder was never patched)."""
    bdir = _backup_dir(install_path)
    if not os.path.isdir(bdir):
        return "no-backup"
    was_patched = _read_marker(install_path) is not None
    mdir = music_dir(install_path)
    touched = False
    for name in (MUSIC_POOL + JINGLE_POOL):
        source = _ogg(bdir, name)
        if os.path.exists(source):
            with open(source, "rb") as f:
                atomic_write(_ogg(mdir, name), f.read(), _TMP_PREFIX)
            touched = True
    safe_remove(_marker_path(install_path))
    if not touched:
        return "no-backup"
    return "restored" if was_patched else "unchanged"
