"""Generate APWandMesh.psk, APWandAnims.psa and APWandTex.png: the project's own
wand model for the Overcompensation Trap's giant wand.

The trap swaps Harry's held wand for a copy with its scale baked in (see
APWandMesh.uc), so the mod needs a wand mesh of its own. This one is drawn
entirely by this script: an octagonal handle and a tapering shaft, one bone,
running from the grip at the origin down the negative Z axis for 20 units, so
the Lumos light's tip offset (APLumosLight.uc) still lands on its tip. The
texture is a generated wood grain. Nothing comes from the game's files.

Outputs (committed; this generator is a dev tool, not shipped):
  mod/HPArchipelago/Models/APWandMesh.psk
  mod/HPArchipelago/Models/APWandAnims.psa
  mod/HPArchipelago/Textures/APWandTex.png   (run scripts/png_to_bmp.py after)

Run: py -3.12 tools/gen_wand_mesh.py
"""

from __future__ import annotations

import math
import random
import struct
from pathlib import Path

from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[1]
MODELS = REPO_ROOT / "mod" / "HPArchipelago" / "Models"
TEXTURES = REPO_ROOT / "mod" / "HPArchipelago" / "Textures"

SIDES = 8
LENGTH = 20.0
# (distance down the wand, radius): pommel, handle, collar, shaft, tip.
PROFILE = [(0.0, 0.42), (0.6, 0.62), (4.6, 0.58), (5.2, 0.66), (5.8, 0.48), (LENGTH, 0.14)]
TEXTURE_SIZE = (32, 128)


# ActorX chunk header type flag.
TYPE_FLAG = 1999801


def ascii_field(text: str, length: int) -> bytes:
    """Fixed-width ASCII field: truncate to length-1 (always NUL-terminated),
    then zero-pad to the full width. Matches the ActorX name encoding."""
    raw = text.encode("ascii")[: length - 1]
    return raw.ljust(length, b"\x00")


def chunk(chunk_id: str, record_size: int, records: list[bytes]) -> bytes:
    """One ActorX chunk: 32-byte header + concatenated records. Header-only
    chunks pass record_size=0 and an empty record list (count stays 0)."""
    if records:
        for rec in records:
            if len(rec) != record_size:
                raise ValueError(
                    f"{chunk_id}: record is {len(rec)} bytes, expected {record_size}"
                )
    count = len(records)
    header = ascii_field(chunk_id, 20) + struct.pack(
        "<iii", TYPE_FLAG, record_size, count
    )
    return header + b"".join(records)


def vbone(name: str) -> bytes:
    """The 120-byte ActorX VBone, shared by PSK REFSKELT and PSA BONENAMES.
    Identity transform: zero rotation quat (0,0,0,1), zero position, unit
    length and unit scale, a single neutral root the weights bind to."""
    rec = (
        ascii_field(name, 64)
        + struct.pack("<I", 0)  # Flags
        + struct.pack("<ii", 0, 0)  # NumChildren, Parent
        + struct.pack("<4f", 0.0, 0.0, 0.0, 1.0)  # Quat XYZW
        + struct.pack("<3f", 0.0, 0.0, 0.0)  # Pos XYZ
        + struct.pack("<f", 1.0)  # Length
        + struct.pack("<3f", 1.0, 1.0, 1.0)  # Size XYZ
    )
    if len(rec) != 120:
        raise ValueError(f"VBone is {len(rec)} bytes, expected 120")
    return rec


def build_psa() -> bytes:
    animinfo = [
        ascii_field("All", 64)
        + ascii_field("None", 64)
        + struct.pack("<4i", 1, 0, 0, 1)  # TotalBones,RootInclude,KeyCompStyle,KeyQuotum
        + struct.pack("<3f", 1.0, 1.0, 30.0)  # KeyReduction,TrackTime,AnimRate
        + struct.pack("<3i", 0, 0, 1)  # StartBone,FirstRawFrame,NumRawFrames
    ]
    animkeys = [
        struct.pack("<3f", 0.0, 0.0, 0.0)  # Pos XYZ
        + struct.pack("<4f", 0.0, 0.0, 0.0, 1.0)  # Quat XYZW
        + struct.pack("<f", 1.0)  # Time
    ]
    return b"".join(
        [
            chunk("ANIMHEAD", 0, []),
            chunk("BONENAMES", 120, [vbone("root")]),
            chunk("ANIMINFO", 168, animinfo),
            chunk("ANIMKEYS", 32, animkeys),
            chunk("SCALEKEYS", 0, []),
        ]
    )


def ring_points(z: float, radius: float) -> list[tuple[float, float, float]]:
    return [(radius * math.cos(2 * math.pi * k / SIDES), radius * math.sin(2 * math.pi * k / SIDES), -z)
            for k in range(SIDES)]


def build_psk() -> bytes:
    points: list[tuple[float, float, float]] = []
    for z, radius in PROFILE:
        points.extend(ring_points(z, radius))
    pommel = len(points)
    points.append((0.0, 0.0, 0.0))
    tip = len(points)
    points.append((0.0, 0.0, -LENGTH - 0.3))

    wedges: list[bytes] = []
    triangles: list[tuple[int, int, int]] = []

    def wedge(point: int, u: float, v: float) -> int:
        wedges.append(struct.pack("<HHffBBH", point, 0, u, v, 0, 0, 0xFFFF))
        return len(wedges) - 1

    for ring in range(len(PROFILE) - 1):
        v0, v1 = PROFILE[ring][0] / LENGTH, PROFILE[ring + 1][0] / LENGTH
        for k in range(SIDES):
            k2 = (k + 1) % SIDES
            a = wedge(ring * SIDES + k, k / SIDES, v0)
            b = wedge(ring * SIDES + k2, (k + 1) / SIDES, v0)
            c = wedge((ring + 1) * SIDES + k2, (k + 1) / SIDES, v1)
            d = wedge((ring + 1) * SIDES + k, k / SIDES, v1)
            triangles += [(a, b, c), (a, c, d)]
    last = (len(PROFILE) - 1) * SIDES
    for k in range(SIDES):
        k2 = (k + 1) % SIDES
        triangles.append((wedge(pommel, 0.5, 0.0), wedge(k2, (k + 1) / SIDES, 0.0), wedge(k, k / SIDES, 0.0)))
        triangles.append((wedge(last + k, k / SIDES, 1.0), wedge(last + k2, (k + 1) / SIDES, 1.0),
                          wedge(tip, 0.5, 1.0)))

    # Both windings, so the wand shows from either side whichever way the engine culls.
    faces = triangles + [(c, b, a) for a, b, c in triangles]

    return b"".join([
        chunk("ACTRHEAD", 0, []),
        chunk("PNTS0000", 12, [struct.pack("<3f", *p) for p in points]),
        chunk("VTXW0000", 16, wedges),
        chunk("FACE0000", 12, [struct.pack("<HHHBBI", a, b, c, 0, 0, 0) for a, b, c in faces]),
        chunk("MATT0000", 88, [ascii_field("APWandTex", 64) + struct.pack("<6i", 0, 0, 0, 0, 0, 0)]),
        chunk("REFSKELT", 120, [vbone("root")]),
        chunk("RAWWEIGHTS", 12, [struct.pack("<fii", 1.0, p, 0) for p in range(len(points))]),
    ])


def build_texture() -> Image.Image:
    """Dark wood: a brown base with long grain streaks along the wand, a darker
    grip band, and a light collar ring."""
    rng = random.Random(1999)
    width, height = TEXTURE_SIZE
    image = Image.new("RGB", TEXTURE_SIZE)
    grain = [rng.uniform(-14, 14) for _ in range(width)]
    for y in range(height):
        along = y / height
        for x in range(width):
            shade = 72 + grain[x] + 8 * math.sin(along * 40 + x * 0.7)
            if along < 0.26:
                shade -= 18
            if 0.26 <= along < 0.29:
                shade += 40
            r, g, b = shade * 1.15, shade * 0.78, shade * 0.52
            image.putpixel((x, y), tuple(max(0, min(255, int(c))) for c in (r, g, b)))
    return image


def main() -> int:
    MODELS.mkdir(parents=True, exist_ok=True)
    (MODELS / "APWandMesh.psk").write_bytes(build_psk())
    (MODELS / "APWandAnims.psa").write_bytes(build_psa())
    build_texture().save(TEXTURES / "APWandTex.png")
    print("wrote", MODELS / "APWandMesh.psk", MODELS / "APWandAnims.psa", TEXTURES / "APWandTex.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
