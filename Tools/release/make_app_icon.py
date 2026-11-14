#!/usr/bin/env python3
"""Draw the app icon — a bot face, lit and rounded, in the same family as the roster's.

Why a script and not a design file: the icon has to match the faces drawn in
`Sources/OpenBotUI/BotSilhouette.swift`, and those are geometry with three numbers per shape. A
drawing that can only be edited by hand drifts the moment a face changes; this renders the same
silhouette from the same normalised points, so the app's mark and the app's bots can be changed in
one place.

The shape is `blob` — the rounded square with every corner melted — because it survives being 16 pt
in a menu bar and is unmistakably one of this app's faces.

Usage:  python3 Tools/release/make_app_icon.py
Writes: Apps/HermesMobile/Assets.xcassets/AppIcon.appiconset/icon-1024.png
        Apps/HermesMac/Assets.xcassets/AppIcon.appiconset/icon_*.png
"""

from __future__ import annotations

import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "Apps/HermesMobile/Assets.xcassets/AppIcon.appiconset"
MAC = ROOT / "Apps/HermesMac/Assets.xcassets/AppIcon.appiconset"

S = 4096  # supersampled canvas; every edge is drawn four times the final size

# The palette is the roster's: `amber` for the light, `orange` for the body, the app's own
# near-black for the plate.
CANVAS_TOP = (38, 33, 42)
CANVAS_BOTTOM = (18, 16, 20)
PLATE_TOP = (52, 46, 58)
PLATE_BOTTOM = (26, 23, 29)
FACE_TOP = (250, 176, 92)     # amber/orange blend, lit from above
FACE_BOTTOM = (232, 122, 72)  # orange, turning away — warm, not muddy
RIM = (255, 214, 160)
EYE = (26, 22, 26)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def vertical_gradient(size, top, bottom):
    """A vertical gradient as an image. Two pixels drawn once and scaled is the whole trick."""
    grad = Image.new("RGB", (1, size), top)
    draw = ImageDraw.Draw(grad)
    for y in range(size):
        draw.point((0, y), lerp(top, bottom, y / max(1, size - 1)))
    return grad.resize((size, size), Image.Resampling.BILINEAR)


def blob_mask(size: int) -> Image.Image:
    """`case .blob` from BotSilhouette: the box inset to 0.06/0.07 and melted corners at 0.33."""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    inset_x, inset_y = size * 0.115, size * 0.125
    box = (inset_x, inset_y, size - inset_x, size - inset_y)
    radius = (box[2] - box[0]) * 0.39
    draw.rounded_rectangle(box, radius=radius, fill=255)
    return mask


def squircle_mask(size: int, radius_ratio: float = 0.2237) -> Image.Image:
    """The macOS plate: Apple's rounded-rectangle proportion, on the 1024 grid."""
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1),
                                           radius=int(size * radius_ratio), fill=255)
    return mask


def compose(size: int) -> Image.Image:
    plate = vertical_gradient(size, PLATE_TOP, PLATE_BOTTOM).convert("RGBA")
    plate.putalpha(squircle_mask(size))

    # A warm pool of light behind the face, so the plate is not a flat field.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        (size * 0.10, size * 0.02, size * 0.90, size * 0.78),
        fill=(255, 168, 96, 58),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.10))
    plate.alpha_composite(Image.composite(glow, Image.new("RGBA", (size, size), (0, 0, 0, 0)),
                                          squircle_mask(size)))

    mask = blob_mask(size)

    # The face's own fill: lit at the top, turning away at the bottom.
    face = vertical_gradient(size, FACE_TOP, FACE_BOTTOM).convert("RGBA")
    face.putalpha(mask)

    # A contact shadow, so the face sits on the plate instead of being pasted on it.
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 150), (0, 0), mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(size * 0.045))
    dropped = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dropped.paste(shadow, (0, int(size * 0.022)))
    plate.alpha_composite(dropped)

    # Tier one of the faces' own light: a highlight from above, a shade below, and an inner rim.
    highlight = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hd = ImageDraw.Draw(highlight)
    hd.ellipse((size * 0.12, size * 0.06, size * 0.88, size * 0.62), fill=(255, 255, 255, 104))
    highlight = highlight.filter(ImageFilter.GaussianBlur(size * 0.07))
    highlight.putalpha(Image.composite(highlight.getchannel("A"),
                                       Image.new("L", (size, size), 0), mask))
    face.alpha_composite(highlight)

    shade = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shade).ellipse(
        (size * 0.02, size * 0.60, size * 0.98, size * 1.02), fill=(78, 26, 14, 82)
    )
    shade = shade.filter(ImageFilter.GaussianBlur(size * 0.08))
    shade.putalpha(Image.composite(shade.getchannel("A"), Image.new("L", (size, size), 0), mask))
    face.alpha_composite(shade)

    rim = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    edge = mask.filter(ImageFilter.FIND_EDGES).filter(ImageFilter.GaussianBlur(size * 0.006))
    rim.paste(RIM + (170,), (0, 0), edge.point(lambda v: min(255, int(v * 1.9))))
    face.alpha_composite(rim)

    # One specular mark, high and left, where a room's light catches a rounded form. Blurred enough
    # to read as a sheen and not as a sticker.
    spark = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(spark).ellipse(
        (size * 0.26, size * 0.13, size * 0.52, size * 0.25), fill=(255, 245, 226, 120)
    )
    spark = spark.filter(ImageFilter.GaussianBlur(size * 0.018))
    spark.putalpha(Image.composite(spark.getchannel("A"), Image.new("L", (size, size), 0), mask))
    face.alpha_composite(spark)

    plate.alpha_composite(face)

    # Two eyes: short, vertical, tipped a couple of degrees — the same proportions the roster uses
    # (0.105 × 0.185 of the face, spaced 0.135 apart, one bar every 0.003 of height).
    eyes = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ed = ImageDraw.Draw(eyes)
    bar_w, bar_h = size * 0.105, size * 0.185
    gap = size * 0.135
    cy = size * 0.5 - size * 0.015
    for cx in (size * 0.5 - gap / 2 - bar_w / 2, size * 0.5 + gap / 2 + bar_w / 2):
        ed.rounded_rectangle((cx - bar_w / 2, cy - bar_h / 2, cx + bar_w / 2, cy + bar_h / 2),
                             radius=bar_w * 0.42, fill=EYE + (196,))
    eyes = eyes.rotate(-4, resample=Image.Resampling.BICUBIC, center=(size / 2, cy))
    plate.alpha_composite(eyes)

    return plate


def main() -> None:
    master = compose(S).resize((1024, 1024), Image.Resampling.LANCZOS)

    IOS.mkdir(parents=True, exist_ok=True)
    ios_icon = Image.new("RGB", (1024, 1024), CANVAS_BOTTOM)
    ios_icon.paste(master.convert("RGB"), (0, 0),
                   master.getchannel("A"))
    ios_icon.save(IOS / "icon-1024.png", optimize=True)

    MAC.mkdir(parents=True, exist_ok=True)
    for side in (16, 32, 128, 256, 512):
        for scale, suffix in ((1, ""), (2, "@2x")):
            px = side * scale
            master.resize((px, px), Image.Resampling.LANCZOS).save(MAC / f"icon_{side}x{side}{suffix}.png",
                                                        optimize=True)

    print(f"wrote {IOS / 'icon-1024.png'} ({ios_icon.size[0]} px, opaque)")
    print(f"wrote {len(list(MAC.glob('icon_*.png')))} mac sizes")


if __name__ == "__main__":
    main()
