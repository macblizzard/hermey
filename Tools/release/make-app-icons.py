#!/usr/bin/env python3
"""Generate the macOS AppIcon.appiconset from the iOS 1024px master artwork.

Why this exists: the mobile master (Apps/HermesMobile/.../icon-1024.png) is a
full-bleed square, because iOS applies its own rounded-rect mask at runtime.
macOS does not: the .icns artwork carries its own squircle shape and margins on a
transparent canvas, otherwise Finder/Dock show a square tile instead of an app.

So every size is produced as: artwork scaled into an 824x824 content square
(Apple's Big Sur+ grid: 1024 minus 100pt padding per side), centred on a
transparent canvas, clipped to a rounded rect of radius 185.4/1024 of the canvas.

Small sizes (16/32/64 px) come from a simplified variant. The master's hairline
accent ring is ~2-3px at 1024, i.e. 0.05px at 16 - it can only smear into grey
mush, so the compact master erases the ring and thickens the H by ~10px at 1024
(0.15px at 16, 0.6px at 64) so the mark still reads. Everything >= 128px uses the
unmodified master.

Usage: python3 Tools/release/make-app-icons.py
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
MASTER = ROOT / "Apps/HermesMobile/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
OUT = ROOT / "Apps/HermesMac/Assets.xcassets/AppIcon.appiconset"

CANVAS = 1024
CONTENT = 824          # Apple squircle content box at 1024
RADIUS = 185.4         # Apple squircle corner radius at 1024
RING_R = 296.0         # hairline accent ring radius in the master, px
RING_IN, RING_OUT = 10, 14   # ring band to erase (plus antialiasing headroom)
CX = CY = 511.5


def is_accent(c):
    r, g, b = c
    return b > 140 and r < 110 and 60 < g < 235 and b - r > 70


def erase_ring(im):
    """Replace the hairline ring (and its glow) with a smooth radial ramp.

    The field around the mark is a radial gradient, so the annulus that held the
    ring is rebuilt by interpolating between the median field colour just inside
    it and just outside it. Endpoints come from the real pixels, so the patch
    meets the untouched field without a seam - a straight pixel-shift copy would
    leave a visible step where the glow fades out.
    """
    px = im.load()
    inside, outside = [], []
    for y in range(CANVAS):
        for x in range(CANVAS):
            c = px[x, y]
            if is_accent(c):
                continue
            r = math.hypot(x - CX, y - CY)
            if 230 <= r <= 245:
                inside.append(c)
            elif 365 <= r <= 395:
                outside.append(c)
    inside.sort(key=lambda c: sum(c))
    outside.sort(key=lambda c: sum(c))
    c_in = inside[len(inside) // 2]
    c_out = outside[len(outside) // 2]

    lo, hi = 246.0, 364.0
    out = im.copy()
    dst = out.load()
    for y in range(CANVAS):
        for x in range(CANVAS):
            r = math.hypot(x - CX, y - CY)
            if not (lo <= r <= hi):
                continue
            t = (r - lo) / (hi - lo)
            t = t * t * (3 - 2 * t)          # smoothstep, no kink at the seams
            dst[x, y] = tuple(round(c_in[i] + t * (c_out[i] - c_in[i])) for i in range(3))
    return out


def build_compact_master(im):
    """Ring-less field with the same H, scaled up and lifted slightly.

    At 16px the mark has to fight for every pixel: 58% of the tile is too timid,
    and #007CF7 on near-black averages down to a dim grey, so the compact variant
    scales the glyph 1.10x and lifts it 15%. Same artwork, same hue.
    """
    px = im.load()
    bg = erase_ring(im)

    glyph = Image.new("L", (CANVAS, CANVAS), 0)
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    gp, lp = glyph.load(), layer.load()
    for y in range(CANVAS):
        for x in range(CANVAS):
            # r < RING_R - 26 keeps the ring's own pixels out of the glyph mask
            if math.hypot(x - CX, y - CY) < RING_R - 26 and is_accent(px[x, y]):
                gp[x, y] = 255
                lp[x, y] = tuple(min(255, round(v * GLYPH_GAIN)) for v in px[x, y]) + (255,)

    alpha = glyph.filter(ImageFilter.GaussianBlur(2))
    alpha = alpha.filter(ImageFilter.MaxFilter(11))     # +5px per side
    alpha = alpha.filter(ImageFilter.GaussianBlur(3))
    layer.putalpha(alpha)

    n = int(CANVAS * SMALL_SCALE)
    big = layer.resize((n, n), Image.LANCZOS)
    off = (CANVAS - n) // 2
    zoomed = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    zoomed.paste(big, (off, off), big)

    bg.paste(zoomed, (0, 0), zoomed)
    return bg


def squircle(size, radius):
    """Rounded-rect alpha, supersampled 4x so 13px tiles still get clean corners."""
    ss = 4
    m = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        (0, 0, size * ss - 1, size * ss - 1), radius=radius * ss, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def mac_master(art):
    """1024px macOS tile: art in the 824 content box, squircle-clipped."""
    tile = art.resize((CONTENT, CONTENT), Image.LANCZOS).convert("RGBA")
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    off = (CANVAS - CONTENT) // 2
    canvas.paste(tile, (off, off))
    canvas.putalpha(squircle(CANVAS, RADIUS))
    return canvas


def render(master, size, sharpen=False):
    """Downsample the whole tile, then re-clip: keeping the resized mask would
    blur the corners, and pasting at an integer offset would leave 13px-in-16px
    artwork off-centre by a pixel."""
    img = master.resize((size, size), Image.LANCZOS)
    if sharpen:
        img = img.filter(ImageFilter.UnsharpMask(radius=1, percent=45, threshold=0))
    mask = squircle(size, size * RADIUS / CANVAS)
    # LANCZOS ringing can leave alpha of 1-3/255 in the far corners; a hard floor
    # keeps the outside of the squircle fully transparent.
    mask = mask.point(lambda v: 0 if v < 8 else v)
    img.putalpha(mask)
    return img


# (pixel size, filename) -- the classic macOS appiconset
SIZES = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]
SMALL = 64   # <= this px, use the simplified ring-less artwork
SMALL_SCALE = 1.10   # optical compensation: a mark that fills 58% reads small at 16px
GLYPH_GAIN = 1.15    # lift the accent a touch so thin strokes survive the downsample


def main():
    master = Image.open(MASTER).convert("RGB")
    compact = build_compact_master(master)

    tiles = {False: mac_master(master), True: mac_master(compact)}

    OUT.mkdir(parents=True, exist_ok=True)
    for size, name in SIZES:
        small = size <= SMALL
        render(tiles[small], size, sharpen=small).save(OUT / name, optimize=True)
        print(f"{size:5d}px  {name}")


if __name__ == "__main__":
    main()
