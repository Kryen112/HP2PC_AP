"""Record a freshly built HPArchipelago.u as the canonical compiled package.

Run from the repo root after an elevated UCC rebuild (scripts\\rebuild_mod.ps1,
kept outside the repo), passing the built package:
    py -3.12 scripts/capture_mod.py "C:\\...\\Modded\\System\\HPArchipelago.u"

Copies the package into mod/Compiled and writes the source-hash manifest that
build_apworld.py verifies before every packaging run. UCC compiles the source
tree mirrored next to the install's System folder (<install>\\HPArchipelago),
so this refuses to record a package whose mirrored source differs from the
repo's mod source: a stale build can never become the canonical package.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from build_apworld import (COMPILED_MANIFEST, COMPILED_PACKAGE, MOD_PACKAGE,
                           MOD_SOURCE_DIR, MOD_SOURCE_GLOBS, manifest_pairs)


def mirrored_source_matches(built_package: Path) -> "list[str]":
    """Differences between the repo's mod source and the source tree UCC
    compiled the package from. An empty list means the build is current."""
    mirrored_dir = built_package.parent.parent / MOD_PACKAGE
    if not mirrored_dir.is_dir():
        return [f"no mirrored source at {mirrored_dir}; was the package built "
                f"by the rebuild script?"]
    problems: list[str] = []
    for pattern in MOD_SOURCE_GLOBS:
        repo_files = {p.relative_to(MOD_SOURCE_DIR).as_posix()
                      for p in MOD_SOURCE_DIR.glob(pattern)}
        mirrored_files = {p.relative_to(mirrored_dir).as_posix()
                          for p in mirrored_dir.glob(pattern)}
        for name in sorted(repo_files - mirrored_files):
            problems.append(f"missing from the build: {name}")
        for name in sorted(mirrored_files - repo_files):
            problems.append(f"built with a file the repo does not have: {name}")
        for name in sorted(repo_files & mirrored_files):
            if (MOD_SOURCE_DIR / name).read_bytes() != (mirrored_dir / name).read_bytes():
                problems.append(f"built from a different version of: {name}")
    return problems


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    built_package = Path(sys.argv[1]).resolve()
    if not built_package.is_file():
        print(f"ERROR: {built_package} not found.", file=sys.stderr)
        return 1
    problems = mirrored_source_matches(built_package)
    if problems:
        print("ERROR: the built package is stale against the repo's mod source. "
              "Rebuild it, then re-run this capture.", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    COMPILED_PACKAGE.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(built_package, COMPILED_PACKAGE)
    pairs = manifest_pairs(MOD_SOURCE_DIR, COMPILED_PACKAGE)
    COMPILED_MANIFEST.write_text(
        "".join(f"{digest} {name}\n" for digest, name in pairs), encoding="ascii")
    print(f"Captured {COMPILED_PACKAGE} ({COMPILED_PACKAGE.stat().st_size // 1024} KB)")
    print(f"Wrote {COMPILED_MANIFEST} ({len(pairs)} entries)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
