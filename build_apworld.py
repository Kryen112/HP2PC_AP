"""Build the harry_potter_2_pc .apworld and install it to the local Archipelago.

Run from the repo root:
    py -3.12 build_apworld.py

Packaging only, no code generation. The apworld Python (access / items / locations
/ regions / rules) and the mod's .uc files are committed source, not generated. This
verifies the committed compiled mod package against its source-hash manifest and
stages it into apworld/data/mod (where the client's installer reads it), invokes
Archipelago's native `Build APWorlds` Launcher to zip the world, then copies the
result into the local custom_worlds dir(s).
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent

# The canonical compiled mod package, committed next to a source-hash manifest.
# Exactly one compiled HPArchipelago.u ships per release; players receive it
# through the apworld (installer.py deploys it), never by compiling locally.
MOD_PACKAGE = "HPArchipelago"
MOD_SOURCE_DIR = REPO_ROOT / "mod" / MOD_PACKAGE
COMPILED_PACKAGE = REPO_ROOT / "mod" / "Compiled" / f"{MOD_PACKAGE}.u"
COMPILED_MANIFEST = REPO_ROOT / "mod" / "Compiled" / f"{MOD_PACKAGE}.u.sources"
# Every build input UCC compiles or #exec-imports into the package.
MOD_SOURCE_GLOBS = ("Classes/*.uc", "Models/*", "Textures/*")

# AP framework checkout: its `Build APWorlds` Launcher component zips the apworld
# for cross-platform distribution (the dev loop's junction is Windows-only). Env
# override for non-standard layouts; default follows the sibling-of-HP2PC_AP
# convention.
AP_FRAMEWORK_DIR = Path(
    os.environ.get("HP2_AP_FRAMEWORK_DIR") or (REPO_ROOT / ".." / ".." / "Archipelago")
).resolve()
APWORLD_GAME_NAME = "Harry Potter 2 PC"

# --- LOCAL ONLY, do not commit -------------------------------------------
# Copy the built apworld into each local Archipelago custom_worlds so the running
# generator / client / launcher pick up the rebuild. Machine-specific; override
# with HP2_APWORLD_INSTALL_DIRS (os.pathsep-separated).
_DEFAULT_APWORLD_INSTALL_DIRS = [
    Path(r"C:\ProgramData\Archipelago\custom_worlds"),
]
APWORLD_INSTALL_DIRS = (
    [Path(p) for p in os.environ["HP2_APWORLD_INSTALL_DIRS"].split(os.pathsep)]
    if os.environ.get("HP2_APWORLD_INSTALL_DIRS")
    else _DEFAULT_APWORLD_INSTALL_DIRS
)
# --- end LOCAL ONLY -------------------------------------------------------


def manifest_pairs(source_dir: Path, compiled: Path) -> "list[tuple[str, str]]":
    """A sorted (sha256, relative path) pair per mod build input plus one for
    the compiled package itself, binding the package bytes to the source they
    were built from. scripts/capture_mod.py records the same pairs."""
    pairs = [
        (hashlib.sha256(path.read_bytes()).hexdigest(),
         path.relative_to(source_dir).as_posix())
        for pattern in MOD_SOURCE_GLOBS
        for path in source_dir.glob(pattern)
    ]
    pairs.append((hashlib.sha256(compiled.read_bytes()).hexdigest(), compiled.name))
    return sorted(pairs)


def verify_manifest() -> None:
    """Check the committed compiled package against its source-hash manifest.
    Raises on a .u whose bytes or sibling sources drifted since the capture.
    Also the pre-commit gate (scripts/check_mod_manifest.py)."""
    if not COMPILED_PACKAGE.is_file() or not COMPILED_MANIFEST.is_file():
        raise FileNotFoundError(
            f"{COMPILED_PACKAGE} or its manifest is missing; rebuild the mod and "
            f"record it with scripts/capture_mod.py"
        )
    expected = manifest_pairs(MOD_SOURCE_DIR, COMPILED_PACKAGE)
    if len(expected) < 2:
        raise FileNotFoundError(f"no mod source found under {MOD_SOURCE_DIR}")
    # Sorted-pair compare, so the manifest's line order, line endings, and
    # trailing whitespace never matter.
    recorded = sorted(
        tuple(line.split(maxsplit=1)) for line
        in COMPILED_MANIFEST.read_text(encoding="ascii").splitlines() if line.strip()
    )
    if recorded != expected:
        raise ValueError(
            "the committed HPArchipelago.u was captured against different mod "
            "source; rebuild the mod and re-run scripts/capture_mod.py"
        )


def stage_mod() -> None:
    """Verify the committed compiled package against its manifest, then stage
    it into apworld/data/mod, where installer.py reads it."""
    verify_manifest()
    staged_dir = REPO_ROOT / "apworld" / "data" / "mod"
    if staged_dir.is_dir():
        shutil.rmtree(staged_dir)
    staged_dir.mkdir(parents=True)
    shutil.copy2(COMPILED_PACKAGE, staged_dir / COMPILED_PACKAGE.name)
    shutil.copy2(COMPILED_MANIFEST, staged_dir / COMPILED_MANIFEST.name)
    print(
        f"Staged {COMPILED_PACKAGE.name} into apworld/data/mod "
        f"({COMPILED_PACKAGE.stat().st_size // 1024} KB)"
    )


def build_apworld_zip() -> "Path | None":
    """Invoke AP's native `Build APWorlds` Launcher to package the apworld dir
    into a cross-platform `.apworld` zip. Returns the zip path, or None on any
    failure (a dev box without the AP checkout still exits cleanly)."""
    launcher = AP_FRAMEWORK_DIR / "Launcher.py"
    if not launcher.is_file():
        print(
            f"WARNING: AP framework not found at {AP_FRAMEWORK_DIR}; cannot build the "
            f".apworld. Set HP2_AP_FRAMEWORK_DIR or place the Archipelago checkout.",
            file=sys.stderr,
        )
        return None
    cmd = [sys.executable, "Launcher.py", "Build APWorlds", APWORLD_GAME_NAME]
    result = subprocess.run(cmd, cwd=AP_FRAMEWORK_DIR, check=False)
    if result.returncode != 0:
        print(f"ERROR: 'Build APWorlds' exited {result.returncode}; .apworld not produced.", file=sys.stderr)
        return None
    zip_path = AP_FRAMEWORK_DIR / "build" / "apworlds" / "harry_potter_2_pc.apworld"
    if not zip_path.is_file():
        print(f"ERROR: Launcher reported success but {zip_path} is missing.", file=sys.stderr)
        return None
    return zip_path


# --- LOCAL ONLY, do not commit -------------------------------------------
def install_apworld(zip_path: Path) -> None:
    """Copy the built apworld into each local custom_worlds dir. Skips missing dirs."""
    for dest_dir in APWORLD_INSTALL_DIRS:
        if not dest_dir.is_dir():
            print(f"  skipped install (no such dir): {dest_dir}")
            continue
        dest = dest_dir / zip_path.name
        shutil.copy2(zip_path, dest)
        print(f"  installed -> {dest}")
# --- end LOCAL ONLY -------------------------------------------------------


def main() -> int:
    stage_mod()
    zip_path = build_apworld_zip()
    if zip_path is None:
        return 1
    print(f"Built {zip_path} ({zip_path.stat().st_size // 1024} KB)")
    install_apworld(zip_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
