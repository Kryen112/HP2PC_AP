"""Generate APGhostGlasses.png: light glasses frames for the ghost players.

A ghost is Harry's mesh drawn translucent, and translucency is additive, so the
dark frames of his own glasses vanish. The ghost lays this texture over the
glasses' texture slot instead. It is drawn here from plain shapes: two rings,
a bridge, edge stubs and a temple band, placed where that slot's layout puts
the frames on a 128 by 128 texture. Everything else is magenta, the colour the
masked import makes transparent. Nothing comes from the game's files.

Output (committed; this generator is a dev tool, not shipped):
  mod/HPArchipelago/Textures/APGhostGlasses.png   (run scripts/png_to_bmp.py after)

Run: py -3.12 tools/gen_ghost_glasses.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parents[1] / "mod" / "HPArchipelago" / "Textures" / "APGhostGlasses.png"
SIZE = 128
SUPERSAMPLE = 4  # drawn at 4x, then reduced without smoothing so the mask stays crisp
MAGENTA = (255, 0, 255)
FRAME = (210, 210, 225)

LENSES = [(31, 31), (97, 31)]
OUTER, INNER = 29, 24


def main() -> int:
    big = Image.new("RGB", (SIZE * SUPERSAMPLE, SIZE * SUPERSAMPLE), MAGENTA)
    draw = ImageDraw.Draw(big)

    def scaled(*values):
        return [v * SUPERSAMPLE for v in values]

    for cx, cy in LENSES:
        draw.ellipse(scaled(cx - OUTER, cy - OUTER, cx + OUTER, cy + OUTER), fill=FRAME)
        draw.ellipse(scaled(cx - INNER, cy - INNER, cx + INNER, cy + INNER), fill=MAGENTA)
    draw.rectangle(scaled(56, 24, 72, 30), fill=FRAME)        # bridge
    draw.rectangle(scaled(0, 20, 6, 30), fill=FRAME)          # left stub
    draw.rectangle(scaled(122, 20, 128, 30), fill=FRAME)      # right stub
    draw.polygon(scaled(0, 64, 0, 72, 128, 92, 128, 84), fill=FRAME)  # temple band
    big.resize((SIZE, SIZE), Image.NEAREST).save(OUT)
    print("wrote", OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
