"""Generate the ghost players' glasses: APGhostGlasses.psk, APGhostGlassesAnims.psa,
APGhostGlasses.png and APGhostNoGlasses.png.

A ghost is Harry's mesh drawn translucent, and translucency is additive, so the
dark frames of his own glasses vanish. The ghost wears a separate pair instead:
this model, drawn solid in a grey blue that matches the ghost's tint,
following the bone where Harry's glasses sit. The
near-black APGhostNoGlasses goes on the ghost's own glasses slot, where it adds
nothing and so hides the faded frames underneath.

The model is drawn from plain shapes, facing +X with +Z up and the bridge at the
origin: two round rims, a bridge and two temples running back, each a solid
bar with depth. One bone and a
one-frame 'All' sequence, like the project's other meshes. Nothing comes from
the game's files.

Outputs (committed; this generator is a dev tool, not shipped):
  mod/HPArchipelago/Models/APGhostGlasses.psk
  mod/HPArchipelago/Models/APGhostGlassesAnims.psa
  mod/HPArchipelago/Textures/APGhostGlasses.png
  mod/HPArchipelago/Textures/APGhostNoGlasses.png   (run scripts/png_to_bmp.py after)

Run: py -3.12 tools/gen_ghost_glasses.py
"""

from __future__ import annotations

import math
import struct
from pathlib import Path

from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[1]
MODELS = REPO_ROOT / "mod" / "HPArchipelago" / "Models"
TEXTURES = REPO_ROOT / "mod" / "HPArchipelago" / "Textures"

RIM_SEGMENTS = 24
LENS_CENTRE_Y = 2.2
RIM_OUTER, RIM_INNER = 1.45, 1.25
# Every frame part is a solid bar this deep, so it holds together from any angle.
DEPTH = 0.22
BRIDGE = (-0.85, 0.85, 0.45, 0.65)           # y from, y to, z from, z to
TEMPLE_Z = (0.34, 0.56)
TEMPLE_WIDTH = 0.22
# The temples run back and outward from the hinges, around the sides of the head.
TEMPLE_LENGTH = 4.5
TEMPLE_SPREAD = 1.2
FRAME_COLOUR = (112, 122, 162)
HIDDEN_COLOUR = (2, 2, 2)
TEXTURE_SIZE = (16, 16)

# ActorX chunk header type flag.
TYPE_FLAG = 1999801


def ascii_field(text: str, length: int) -> bytes:
    """Fixed-width ASCII field, NUL-terminated and zero-padded (ActorX names)."""
    raw = text.encode("ascii")[: length - 1]
    return raw.ljust(length, b"\x00")


def chunk(chunk_id: str, record_size: int, records: list[bytes]) -> bytes:
    """One ActorX chunk: 32-byte header plus the concatenated records."""
    for rec in records:
        if len(rec) != record_size:
            raise ValueError(f"{chunk_id}: record is {len(rec)} bytes, expected {record_size}")
    header = ascii_field(chunk_id, 20) + struct.pack("<iii", TYPE_FLAG, record_size, len(records))
    return header + b"".join(records)


def vbone(name: str) -> bytes:
    """The 120-byte ActorX VBone: a single neutral root with identity transform."""
    rec = (
        ascii_field(name, 64)
        + struct.pack("<I", 0)
        + struct.pack("<ii", 0, 0)
        + struct.pack("<4f", 0.0, 0.0, 0.0, 1.0)
        + struct.pack("<3f", 0.0, 0.0, 0.0)
        + struct.pack("<f", 1.0)
        + struct.pack("<3f", 1.0, 1.0, 1.0)
    )
    if len(rec) != 120:
        raise ValueError(f"VBone is {len(rec)} bytes, expected 120")
    return rec


def build_psa() -> bytes:
    animinfo = [
        ascii_field("All", 64)
        + ascii_field("None", 64)
        + struct.pack("<4i", 1, 0, 0, 1)
        + struct.pack("<3f", 1.0, 1.0, 30.0)
        + struct.pack("<3i", 0, 0, 1)
    ]
    animkeys = [struct.pack("<3f", 0.0, 0.0, 0.0) + struct.pack("<4f", 0.0, 0.0, 0.0, 1.0) + struct.pack("<f", 1.0)]
    return b"".join([
        chunk("ANIMHEAD", 0, []),
        chunk("BONENAMES", 120, [vbone("root")]),
        chunk("ANIMINFO", 168, animinfo),
        chunk("ANIMKEYS", 32, animkeys),
        chunk("SCALEKEYS", 0, []),
    ])


def build_psk() -> bytes:
    points: list[tuple[float, float, float]] = []
    quads: list[tuple[int, int, int, int]] = []

    index: dict[tuple[float, float, float], int] = {}

    # Faces share their corners, so the engine sees one connected frame.
    def point(x: float, y: float, z: float) -> int:
        key = (round(x, 4), round(y, 4), round(z, 4))
        if key not in index:
            points.append(key)
            index[key] = len(points) - 1
        return index[key]

    def quad(corners: list[tuple[float, float, float]]) -> None:
        quads.append(tuple(point(*c) for c in corners))

    def box(x0: float, x1: float, y0: float, y1: float, z0: float, z1: float) -> None:
        quad([(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)])
        quad([(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)])
        quad([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)])
        quad([(x0, y0, z0), (x0, y1, z0), (x1, y1, z0), (x1, y0, z0)])
        quad([(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)])
        quad([(x0, y1, z0), (x0, y1, z1), (x1, y1, z1), (x1, y1, z0)])

    front, back = DEPTH / 2, -DEPTH / 2
    for centre_y in (-LENS_CENTRE_Y, LENS_CENTRE_Y):
        for k in range(RIM_SEGMENTS):
            a0 = 2 * math.pi * k / RIM_SEGMENTS
            a1 = 2 * math.pi * (k + 1) / RIM_SEGMENTS

            def at(radius: float, angle: float, x: float) -> tuple[float, float, float]:
                return (x, centre_y + radius * math.cos(angle), radius * math.sin(angle))

            for x in (front, back):
                quad([at(RIM_INNER, a0, x), at(RIM_OUTER, a0, x), at(RIM_OUTER, a1, x), at(RIM_INNER, a1, x)])
            quad([at(RIM_OUTER, a0, front), at(RIM_OUTER, a0, back), at(RIM_OUTER, a1, back), at(RIM_OUTER, a1, front)])
            quad([at(RIM_INNER, a0, front), at(RIM_INNER, a1, front), at(RIM_INNER, a1, back), at(RIM_INNER, a0, back)])
    y0, y1, z0, z1 = BRIDGE
    box(back, front, y0, y1, z0, z1)
    edge = LENS_CENTRE_Y + RIM_OUTER - 0.08
    z0, z1 = TEMPLE_Z
    for side in (-1.0, 1.0):
        # A bar from the hinge at the front to the far end, set back and out.
        near_in, near_out = side * edge, side * (edge + TEMPLE_WIDTH)
        far_in, far_out = near_in + side * TEMPLE_SPREAD, near_out + side * TEMPLE_SPREAD
        hinge_x, end_x = front, -TEMPLE_LENGTH
        corners = {
            "a": (hinge_x, near_in), "b": (hinge_x, near_out),
            "c": (end_x, far_out), "d": (end_x, far_in),
        }
        top = [(x, y, z1) for x, y in (corners[k] for k in "abcd")]
        bottom = [(x, y, z0) for x, y in (corners[k] for k in "abcd")]
        quad(top)
        quad(bottom[::-1])
        for i in range(4):
            j = (i + 1) % 4
            quad([bottom[i], bottom[j], top[j], top[i]])

    wedges = [struct.pack("<HHffBBH", p, 0, 0.5, 0.5, 0, 0, 0xFFFF) for p in range(len(points))]
    triangles = []
    for a, b, c, d in quads:
        triangles += [(a, b, c), (a, c, d)]
    # Both windings, so the frames show from either side whichever way the engine culls.
    faces = triangles + [(c, b, a) for a, b, c in triangles]

    return b"".join([
        chunk("ACTRHEAD", 0, []),
        chunk("PNTS0000", 12, [struct.pack("<3f", *p) for p in points]),
        chunk("VTXW0000", 16, wedges),
        chunk("FACE0000", 12, [struct.pack("<HHHBBI", a, b, c, 0, 0, 0) for a, b, c in faces]),
        chunk("MATT0000", 88, [ascii_field("APGhostGlasses", 64) + struct.pack("<6i", 0, 0, 0, 0, 0, 0)]),
        chunk("REFSKELT", 120, [vbone("root")]),
        chunk("RAWWEIGHTS", 12, [struct.pack("<fii", 1.0, p, 0) for p in range(len(points))]),
    ])


def main() -> int:
    MODELS.mkdir(parents=True, exist_ok=True)
    (MODELS / "APGhostGlasses.psk").write_bytes(build_psk())
    (MODELS / "APGhostGlassesAnims.psa").write_bytes(build_psa())
    Image.new("RGB", TEXTURE_SIZE, FRAME_COLOUR).save(TEXTURES / "APGhostGlasses.png")
    Image.new("RGB", TEXTURE_SIZE, HIDDEN_COLOUR).save(TEXTURES / "APGhostNoGlasses.png")
    print("wrote", MODELS / "APGhostGlasses.psk", MODELS / "APGhostGlassesAnims.psa",
          TEXTURES / "APGhostGlasses.png", TEXTURES / "APGhostNoGlasses.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
