"""Convert the mod's PNG textures to the 8-bit palettized BMPs the retail
importer reads.

    py -3.12 scripts/png_to_bmp.py

Writes mod/HPArchipelago/Textures/<name>.bmp next to each <name>.png. A texture
that uses magenta (255,0,255) as its chroma key gets magenta at palette index 0,
the index a masked texture draws as transparent. Any other texture is quantized
to a plain 256-colour palette.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image

TEXTURES = Path(__file__).resolve().parents[1] / "mod" / "HPArchipelago" / "Textures"
MAGENTA = (255, 0, 255)


def palettize(source: Path) -> Image.Image:
    rgb = Image.open(source).convert("RGB")
    pixels = list(rgb.getdata())
    if MAGENTA not in pixels:
        return rgb.quantize(256, dither=Image.Dither.NONE)

    # Quantize only the visible pixels, then shift their indices up by one so
    # index 0 is free for the chroma key.
    visible = [p for p in pixels if p != MAGENTA] or [(0, 0, 0)]
    sample = Image.new("RGB", (len(visible), 1))
    sample.putdata(visible)
    quantized = sample.quantize(255, dither=Image.Dither.NONE)
    palette = quantized.getpalette()[:255 * 3]
    remapped = rgb.quantize(palette=quantized, dither=Image.Dither.NONE)
    indices = [0 if p == MAGENTA else index + 1
               for p, index in zip(pixels, remapped.getdata())]
    result = Image.new("P", rgb.size)
    result.putpalette(list(MAGENTA) + palette + [0] * (3 * 256 - 3 - len(palette)))
    result.putdata(indices)
    return result


def main() -> int:
    for source in sorted(TEXTURES.glob("*.png")):
        target = source.with_suffix(".bmp")
        palettize(source).save(target)
        print(f"{source.name} -> {target.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
