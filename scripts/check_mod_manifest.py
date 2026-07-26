"""Pre-commit gate: the mod source and the canonical compiled package must
match, so no commit can carry a drifted pair. Runs build_apworld's own
manifest verification, verify-only (nothing is staged or written). Fails when
mod source changed without a rebuild + capture, when the committed .u or its
manifest is missing, or when either was edited by hand; the fix is always the
same: rebuild the mod and re-run scripts/capture_mod.py (rebuild_mod.ps1 does
both).
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from build_apworld import verify_manifest


def main() -> int:
    try:
        verify_manifest()
    except (FileNotFoundError, ValueError) as error:
        print(f"mod / compiled package drift: {error}", file=sys.stderr)
        return 1
    print("mod source and the compiled package match")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
