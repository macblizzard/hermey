"""Measure the bend: where the page's own edges land inside the body, and where they would have.

Why: the round-4 critique's test is "the page's edges visibly bend under the body". A picture shows
that to an eye that is looking for it; this says it as a number, so a step can be compared with the
last one. For the horizontal bars the proof's page draws, each column's bar edge has a y. Outside the
body it is where the page put it; inside the body it is where the traced ray moved it. The difference
is the refraction, measured in the same points the body was drawn in.

Usage:  python3 bend.py <composited-page.png> <side-in-points> [--bar 0.47] [--scale 2]
"""
from __future__ import annotations

import argparse
import os
import sys

# `numbers.py` sits beside this file and shadows the standard library's `numbers`, which numpy imports.
# This script wants numpy, not the mirror, so its own directory comes off the path first.
sys.path = [path for path in sys.path
            if os.path.abspath(path or ".") != os.path.dirname(os.path.abspath(__file__))]

import numpy as np
from PIL import Image


def luma(image: np.ndarray) -> np.ndarray:
    return 0.2126 * image[:, :, 0] + 0.7152 * image[:, :, 1] + 0.0722 * image[:, :, 2]


def edge_rows(column: np.ndarray, guess: int, reach: int) -> float | None:
    """The row where the bar's *top* edge sits in this column, to sub-pixel, or None.

    The bar is a step up in luminance over the pane; the edge is the steepest rise near `guess`, which
    is where the page drew it. A soft edge is a ramp, so the crossing of the halfway level between the
    local floor and the bar's own level is taken rather than the derivative's peak — that is the
    position a person would point at, and it is stable under the body's own darkening of the bar.
    """
    window = column[max(0, guess - reach):guess + reach]
    if window.size < 8:
        return None
    floor, top = np.percentile(window, 8), np.percentile(window, 92)
    if top - floor < 0.02:
        return None
    level = floor + 0.5 * (top - floor)
    above = np.nonzero(window > level)[0]
    if above.size == 0:
        return None
    first = above[0]
    # A crossing at the window's own edge is not a measurement: the edge is outside the search, and
    # reporting the window's boundary as the bar's position is what turned a missing reading into a
    # phantom 20 pt "tear" at the silhouette.
    if first <= 1 or first >= window.size - 1:
        return None
    y0, y1 = window[first - 1], window[first]
    fraction = (level - y0) / max(y1 - y0, 1e-6)
    return float(max(0, guess - reach) + first - 1 + fraction)


def rule_columns(image: np.ndarray, guess: int, reach: int) -> list[tuple[int, float]]:
    """The vertical rule's x in every row, or nothing where it is too dim to find.

    The rule is the page's own vertical edge, and the ray displaces it *sideways* — the half of the bend
    a horizontal bar cannot show. Same crossing rule as the bars, transposed.
    """
    height, width = image.shape[:2]
    out = []
    for y in range(height):
        window = image[y, max(0, guess - reach):guess + reach]
        if window.size < 8:
            continue
        floor, top = np.percentile(window, 8), np.percentile(window, 92)
        if top - floor < 0.02:
            continue
        level = floor + 0.5 * (top - floor)
        above = np.nonzero(window > level)[0]
        if above.size == 0:
            continue
        first = above[0]
        if first <= 1 or first >= window.size - 1:
            continue
        y0, y1 = window[first - 1], window[first]
        fraction = (level - y0) / max(y1 - y0, 1e-6)
        out.append((y, max(0, guess - reach) + first - 1 + fraction))
    return out


def displacement_map(image: np.ndarray, side: float) -> dict:
    """The refraction, subtracted instead of measured.

    `-uv.png` is the same pass writing the *page coordinate* each pixel sampled into the colour: red is
    x, green is y, over the whole page (`(pagePoint + side) / 3·side`). Decoding it and subtracting the
    pixel's own position gives the displacement in points, with no feature detection and nothing for an
    eye to recognise — the map is the ray, not a picture of what it hit.
    """
    height, width = image.shape[:2]
    pixels_per_point = width / side
    decoded = image * 3.0 * side - side          # back into the body's own points
    y, x = np.mgrid[0:height, 0:width]
    own = np.stack([(x + 0.5) / pixels_per_point, (y + 0.5) / pixels_per_point], axis=-1)
    # The debug pass writes the coordinate everywhere the body covers, and the composite leaves the
    # page black outside it — a zero red channel is nothing to measure.
    inside = (image[:, :, 0] + image[:, :, 1]) > 1e-4
    if not inside.any():
        return {"inside": 0}
    shift = decoded[inside] - own[inside]
    radius = np.hypot(shift[:, 0], shift[:, 1])
    return {"inside": int(inside.sum()), "min": float(shift.min()), "max": float(shift.max()),
            "mean": float(shift.mean()), "radius": float(radius.mean()),
            "radiusMax": float(radius.max())}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("png")
    parser.add_argument("side", type=float, help="the body's side in points (the image is side*scale)")
    parser.add_argument("--bar", type=float, default=0.47,
                        help="the bar's y as a fraction of the page (0.36, 0.415, 0.47, 0.525, 0.58)")
    parser.add_argument("--mask", default=None,
                        help="the body's silhouette (default: the -pane.png beside the -uv.png)")
    parser.add_argument("--uv", action="store_true",
                        help="measure the coordinate map (-uv.png) instead of a feature of the page")
    parser.add_argument("--rule", type=float, default=None,
                        help="measure the vertical rule at this fraction of the page instead of a bar")
    parser.add_argument("--scale", type=float, default=2.0)
    arguments = parser.parse_args()

    image = np.asarray(Image.open(arguments.png).convert("RGB")).astype(np.float64) / 255.0
    height, width = image.shape[:2]
    # The image is the *body's box*, not the page: the proof renders the avatar's own layer, so a
    # point's layer coordinate is its image coordinate over the scale. The page is three body-widths
    # across and starts one body-width above and left of the box, which is how a page coordinate
    # becomes a layer one.
    page = 3 * arguments.side
    pixels_per_point = width / arguments.side
    guess = int((arguments.bar * page - arguments.side) * pixels_per_point)
    # The search window has to be wider than the bend itself, or the instrument reports nothing exactly
    # where the lens is strongest: the displacement reaches a tenth of the body, so the window is a
    # fifth of the page in both directions from where the page drew the bar.
    reach = int(page * 0.10 * pixels_per_point)

    if arguments.uv:
        rgb = np.asarray(Image.open(arguments.png).convert("RGB")).astype(np.float64) / 255.0
        # The map is written for the whole quad, not only the body, so the measurement is restricted to
        # the body by another render of it: the flat-pane picture beside the map, whose corner is the
        # page and whose anything-else is the body.
        mask_path = arguments.mask or arguments.png.replace("-uv.png", "-pane.png")
        picture = rgb[:, :, :2]
        try:
            pane = np.asarray(Image.open(mask_path).convert("RGB")).astype(np.float64) / 255.0
            page_colour = pane[2, 2]
            covered = np.abs(pane - page_colour).max(axis=2) > 0.02
            picture = np.where(covered[:, :, None], picture, 0.0)
        except OSError:
            pass
        result = displacement_map(picture, arguments.side)
        print(f"{arguments.png}")
        if not result.get("inside"):
            print("  bend: no body in this render — is it the -uv.png?")
            return
        print(f"  the traced ray lands {result['radius']:.1f} pt from the pixel on average "
              f"(up to {result['radiusMax']:.1f} pt), over {result['inside']} pixels")
        print(f"  lateral shift {result['min']:+.1f} … {result['max']:+.1f} pt")
        print(f"  verdict: {'BENDS' if result['radiusMax'] > 1.5 else 'FLAT'} — a flat body would "
              f"write zero everywhere")
        return

    if arguments.rule is not None:
        guess_x = int((arguments.rule * page - arguments.side) * pixels_per_point)
        # A narrow window: the rule is five points wide, and a wide search finds the body's own bright
        # rim first (which is how this mode first reported a column half the rule's distance away).
        widen = max(4, int(arguments.side * 0.05 * pixels_per_point))
        found = rule_columns(luma(image), guess_x, widen)
        if not found:
            print("bend: no vertical rule found — is this the page render?")
            return
        outside = [x for y, x in found if y < height * 0.30 or y > height * 0.70]
        straight = float(np.median(outside)) if outside else float(np.median([x for _, x in found]))
        inside = [(y, x) for y, x in found if height * 0.34 < y < height * 0.66]
        shifts = np.array([x - straight for _, x in inside]) / pixels_per_point
        print(f"{arguments.png}")
        print(f"  vertical rule at x={arguments.rule:.3f} of the page; straight column "
              f"{straight:.1f} px ({(straight / pixels_per_point):.1f} pt)")
        print(f"  inside the body it moves {shifts.min():+.1f} … {shifts.max():+.1f} pt "
              f"({np.ptp(shifts):.1f} pt across the body)")
        print(f"  largest step between neighbouring rows: "
              f"{np.abs(np.diff(shifts)).max() / pixels_per_point:.2f} pt per point")
        print(f"  verdict: {'BENDS' if np.ptp(shifts) > 1.5 else 'FLAT'}")
        return

    rows, values = [], []
    for x in range(width):
        row = edge_rows(luma(image)[:, x], guess, reach)
        if row is None:
            continue
        rows.append((x, row))

    if not rows:
        print("bend: no bar edge found — is this the page render?")
        return

    # The bar's row where the page is unobstructed: the columns outside the body's box (the body is
    # the middle third of the image).
    outside = [row for x, row in rows if abs(x - width / 2) > 0.44 * width]
    if not outside:
        outside = [row for _, row in rows]
    straight = float(np.median(outside))

    inside = [(x, row) for x, row in rows if abs(x - width / 2) < 0.34 * width]
    if not inside:
        print("bend: no columns inside the body")
        return

    displacements = np.array([row - straight for _, row in inside]) / pixels_per_point
    columns = np.array([x for x, _ in inside]) / pixels_per_point

    print(f"{arguments.png}")
    print(f"  bar at y={arguments.bar:.3f} of the page; straight row {straight:.1f} px "
          f"({straight / pixels_per_point:.1f} pt)")
    print(f"  inside the body, the bar moves by {displacements.min():+.1f} … "
          f"{displacements.max():+.1f} pt (median {np.median(displacements):+.1f})")

    # The interior only: the two columns either side of the silhouette are the page *outside* the body
    # against the page *inside* it, and their difference is the edge, not a tear.
    margin = max(4, len(displacements) // 10)
    interior = displacements[margin:-margin]
    if interior.size < 8:
        interior = displacements
    # Curvature, not offset: a bar that is merely shifted is straight, and a straight bar is a filter.
    # The local slope of the bar's row across the body is what an eye reads as a lens.
    slopes = np.abs(np.diff(interior))
    print(f"  across the interior (left → right): " +
          " ".join(f"{value:+.1f}" for value in interior[::max(1, len(interior) // 12)]))
    print(f"  bend: the bar's row moves {np.ptp(interior):.1f} pt across the body, by at most "
          f"{slopes.max():.1f} pt between neighbouring columns "
          f"({np.degrees(np.arctan(slopes.max())):.1f}° of tilt)")
    moved = float(np.ptp(interior))
    print(f"  verdict: {'BENDS' if moved > 1.5 else 'FLAT'} — a tilted bar inside the body is the "
          f"page seen through a lens; a horizontal one is a filter")


if __name__ == "__main__":
    main()
