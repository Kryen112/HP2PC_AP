"""Smoke test: run AP `Generate.py` N times against tests/HP2_Test.yaml and
assert every run succeeds. Catches regressions in the apworld python (logic
graph cycles, unfillable seeds, item/location count mismatch, broken plando)
without needing the game running.

Each run uses AP's default random-seed picker so N runs exercise N distinct
fill patterns. Output goes to a temp dir per run and is wiped after — we
don't care about the zip, only the exit code.

Usage:
    py -3.12 tests/test_generation.py            # default N=25
    py -3.12 tests/test_generation.py --count 100
    py -3.12 tests/test_generation.py --ap C:/path/to/Archipelago

Exit code 0 = all seeds generated cleanly. Non-zero = at least one failed,
last failure's stderr printed.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
# Repo lives at .../Archipelago-play/Harry Potter 2 PC/HP2PC_AP/. AP framework
# is sibling of the "Harry Potter 2 PC" folder — two .parents up from the repo.
DEFAULT_AP = REPO_ROOT.parent.parent / "Archipelago"
PLAYERS_DIR = REPO_ROOT / "tests"


def run_one(ap_dir: Path, players_dir: Path, output_dir: Path) -> tuple[int, str, str]:
    proc = subprocess.run(
        [
            sys.executable,
            "Generate.py",
            "--player_files_path", str(players_dir),
            "--outputpath", str(output_dir),
            "--plando", "items",
        ],
        cwd=str(ap_dir),
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--count", type=int, default=25, help="Number of seeds to generate (default: 25)")
    parser.add_argument("--ap", type=Path, default=DEFAULT_AP, help=f"Path to Archipelago checkout (default: {DEFAULT_AP})")
    args = parser.parse_args()

    ap_dir: Path = args.ap.resolve()
    if not (ap_dir / "Generate.py").is_file():
        print(f"ERROR: AP framework not found at {ap_dir} (no Generate.py)", file=sys.stderr)
        return 2
    if not PLAYERS_DIR.is_dir():
        print(f"ERROR: tests dir missing: {PLAYERS_DIR}", file=sys.stderr)
        return 2

    yamls = sorted(PLAYERS_DIR.glob("*.yaml"))
    if not yamls:
        print(f"ERROR: no *.yaml player files in {PLAYERS_DIR}", file=sys.stderr)
        return 2

    print(f"Generating {args.count} seed(s) using {ap_dir} ({len(yamls)} player file(s))...")
    start = time.monotonic()
    failures: list[tuple[int, str, str]] = []
    with tempfile.TemporaryDirectory(prefix="hp2pc_ap_test_") as tmp:
        # AP's --player_files_path slurps EVERY file in the directory as YAML.
        # The repo's tests/ dir holds this script alongside the slot YAMLs,
        # so we hand AP a temp dir containing only the YAMLs.
        players_tmp = Path(tmp) / "players"
        players_tmp.mkdir()
        for y in yamls:
            shutil.copy2(y, players_tmp / y.name)

        out = Path(tmp) / "output"
        out.mkdir()

        for i in range(args.count):
            rc, stdout, stderr = run_one(ap_dir, players_tmp, out)
            if rc != 0:
                failures.append((i + 1, stdout, stderr))
                print(f"  seed {i+1}/{args.count}: FAIL (exit {rc})")
                # Stop on first failure — printing 100 tracebacks is noise.
                break
            if (i + 1) % 5 == 0 or (i + 1) == args.count:
                print(f"  seed {i+1}/{args.count}: ok")
            # Wipe between runs so we don't accumulate zips.
            for p in out.glob("*"):
                if p.is_dir():
                    shutil.rmtree(p, ignore_errors=True)
                else:
                    try:
                        p.unlink()
                    except OSError:
                        pass

    elapsed = time.monotonic() - start
    if failures:
        i, stdout, stderr = failures[0]
        print(f"\nFAILURE at seed {i}. Last 2KB of stderr:", file=sys.stderr)
        print(stderr[-2000:], file=sys.stderr)
        if stdout.strip():
            print(f"\nLast 1KB of stdout:", file=sys.stderr)
            print(stdout[-1000:], file=sys.stderr)
        print(f"\n{i-1} of {args.count} succeeded before failure ({elapsed:.1f}s)", file=sys.stderr)
        return 1

    print(f"\nAll {args.count} seeds generated cleanly in {elapsed:.1f}s ({elapsed/args.count*1000:.0f} ms/seed avg).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
