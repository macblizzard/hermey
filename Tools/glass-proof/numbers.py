"""The glass body's numbers without a GPU: a mirror of `HermeyGlassSource.msl`'s fragment, evaluated.

Why: the glass is a Metal pass, and the PNG proof (`Tools/glass-proof/main.swift`) needs a Mac. This
script answers the same question with arithmetic — what colour, what alpha, what gradient — at the
points a person would look at: the body's centre, half way out, and the rim, at 24, 48 and 200 pt.

It mirrors, line for line, what the shader does *and* what the app feeds it:

* the view transform — `OpenBotAvatarRenderer.bodyTransform` (the plane at z = 0, the body's own
  motion, the viewport), with the idle pose's rest yaw and pitch;
* the body's own numbers — `OpenBotAvatarVolume.makePart`'s inscribed thickness, `partDepth`, `rxy`,
  `rz`, and `OpenBotAvatarModel.glassProfile`'s maximum over the parts;
* `BotAvatarGlassSurface.make`'s `shape`, `profile`, `pose` and `tone`;
* the shader's `sampleGlassPlate`, `sampleOuterStudio`, `sampleInternalStudio`, the hood, the rim,
  the inner line, the tone map and the alpha composite;
* the distance field the mask carries — here computed exactly against the outline's segments, where
  the app's `BotAvatarGlassDrawer.distanceField` chamfers a raster, so the numbers agree to well
  under a point.

Not mirrored, and named so nobody mistakes it: the real silhouette is the *softened* preset (an
authored corner under 20° gets a 5 % fillet) and this flattens the authored path; the working pose's
lean and turn; and the texture's 8-bit quantisation of the field.

Run:  python3 Tools/glass-proof/numbers.py            (no dependencies)
"""

from __future__ import annotations

import math
import re

# ---------------------------------------------------------------- the definition

# `OpenBotAvatarPresets.cat`'s authored outline, before `OpenBotAvatarSoften`.
CAT = ("M26 42 L26 16 L44 30 C48 28 52 28 56 30 L74 16 L74 42 "
       "C82 50 82 64 74 72 C66 80 34 80 26 72 C18 64 18 50 26 42 Z")

# `OpenBotAvatarPose.restYaw` / `restPitch` — the pose a reduced-motion (still) frame holds.
REST_YAW, REST_PITCH = -0.30, 0.20

# The house body colour, `OpenBotAvatarRenderer.defaultColor`, in sRGB.
TINT = (1.0, 0.416, 0.102)

# `GlassPulse(rim: 0.55, halo: 0.20)` for `idle`: a steady state, so a still frame reads 0.55.
IDLE_RIM = 0.55


def flatten(path: str, steps: int = 32):
    tokens = re.findall(r"[MLCQZ]|-?\d+\.?\d*", path)
    points, current, start, i = [], (0.0, 0.0), (0.0, 0.0), 0
    while i < len(tokens):
        command = tokens[i]
        i += 1
        if command == "M":
            current = (float(tokens[i]), float(tokens[i + 1]))
            i += 2
            start = current
            points.append(current)
        elif command == "L":
            current = (float(tokens[i]), float(tokens[i + 1]))
            i += 2
            points.append(current)
        elif command == "C":
            control1 = (float(tokens[i]), float(tokens[i + 1]))
            control2 = (float(tokens[i + 2]), float(tokens[i + 3]))
            end = (float(tokens[i + 4]), float(tokens[i + 5]))
            i += 6
            origin = current
            for step in range(1, steps + 1):
                t = step / steps
                a = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t * t, t ** 3
                points.append((a[0] * origin[0] + a[1] * control1[0] + a[2] * control2[0] + a[3] * end[0],
                               a[0] * origin[1] + a[1] * control1[1] + a[2] * control2[1] + a[3] * end[1]))
            current = end
        elif command == "Q":
            control = (float(tokens[i]), float(tokens[i + 1]))
            end = (float(tokens[i + 2]), float(tokens[i + 3]))
            i += 4
            origin = current
            for step in range(1, steps + 1):
                t = step / steps
                a = (1 - t) ** 2, 2 * (1 - t) * t, t * t
                points.append((a[0] * origin[0] + a[1] * control[0] + a[2] * end[0],
                               a[0] * origin[1] + a[1] * control[1] + a[2] * end[1]))
            current = end
        elif command == "Z":
            break
    return points[:-1] if points and points[-1] == points[0] else points


OUTLINE = flatten(CAT)


def face_transform(side: float, yaw: float, pitch: float):
    """`bodyTransform`, with the root's identity (a still frame: no roll, no squash, no lift)."""
    unit = side / 100.0
    cos_yaw, sin_yaw = math.cos(yaw), math.sin(yaw)
    cos_pitch, sin_pitch = math.cos(pitch), math.sin(pitch)
    box = bounds(OUTLINE)
    pivot = ((box[0] + box[1]) / 2, (box[2] + box[3]) / 2)
    a = cos_yaw
    b = sin_yaw * sin_pitch
    c = 0.0
    d = cos_pitch
    tx = pivot[0] - cos_yaw * pivot[0]
    ty = pivot[1] - cos_pitch * pivot[1] - sin_yaw * sin_pitch * pivot[0]

    def transform(x: float, y: float):
        px, py = a * x + c * y + tx, b * x + d * y + ty
        return px * unit, py * unit

    return transform, math.sqrt(abs(a * d - b * c)) * unit


def bounds(points):
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return min(xs), max(xs), min(ys), max(ys)


# ---------------------------------------------------------------- the body's own numbers


def distance_to_outline(point, outline):
    """(signed distance, direction pointing inland): exact against the outline's segments."""
    px, py = point
    best = (1e9, 0.0, 0.0)
    for i in range(len(outline)):
        ax, ay = outline[i]
        bx, by = outline[(i + 1) % len(outline)]
        ex, ey = bx - ax, by - ay
        length2 = ex * ex + ey * ey
        t = 0.0 if length2 == 0 else max(0.0, min(1.0, ((px - ax) * ex + (py - ay) * ey) / length2))
        qx, qy = ax + ex * t, ay + ey * t
        dx, dy = px - qx, py - qy
        distance = math.hypot(dx, dy)
        if distance < best[0]:
            best = (distance, dx, dy)
    distance, dx, dy = best
    inside = point_in_polygon(point, outline)
    norm = math.hypot(dx, dy) or 1.0
    # Inside, the nearest boundary is behind: the inland direction points the other way.
    return (distance if inside else -distance), (-dx / norm, -dy / norm)


def point_in_polygon(point, outline):
    x, y = point
    inside = False
    for i in range(len(outline)):
        x0, y0 = outline[i]
        x1, y1 = outline[(i + 1) % len(outline)]
        if (y0 > y) != (y1 > y):
            if x < x0 + (y - y0) / (y1 - y0) * (x1 - x0):
                inside = not inside
    return inside


def surface(side: float):
    """`BotAvatarGlassSurface.make`, plus the volume numbers it scales."""
    face, points_per_unit = face_transform(side, REST_YAW, REST_PITCH)
    moved = [face(*p) for p in OUTLINE]
    min_x, max_x, min_y, max_y = bounds(moved)

    # The part's own depth: `makePart` takes the largest inscribed radius as half the thickness.
    inscribed = 0.0
    step = 0.5
    y = min_y
    while y <= max_y:
        x = min_x
        while x <= max_x:
            distance, _ = distance_to_outline((x, y), moved)
            if distance > inscribed:
                inscribed = max(inscribed, distance / points_per_unit)
            x += step * points_per_unit
        y += step * points_per_unit
    thickness = 2 * inscribed
    long = max(max_x - min_x, max_y - min_y) / points_per_unit
    depth = min(30.0, max(3.0, 0.8 * max(thickness, min(0.4 * long, 2.4 * thickness))))
    rxy = min(thickness / 2, depth / 2) * 0.9
    rz = (depth / 2) * 0.85
    half_depth = depth / 2

    half_w = (max_x - min_x) / 2
    half_h = (max_y - min_y) / 2
    corner = min(rxy * points_per_unit, min(half_w, half_h))
    detail = 1.0 if side >= 48 else 0.0
    return {
        "size": side,
        "outline": moved,
        "half": (half_w, half_h),
        "centre": ((min_x + max_x) / 2, (min_y + max_y) / 2),
        "corner": corner,
        "rxy": rxy * points_per_unit,
        "rz": rz * points_per_unit,
        "halfDepth": half_depth * points_per_unit,
        "pointsPerUnit": points_per_unit,
        "detail": detail,
        "rim": IDLE_RIM,
        "thickness": thickness,
        "depth": depth,
        "rawRxy": rxy,
        "rawRz": rz,
    }


# ---------------------------------------------------------------- the fragment


def mix(a: float, b: float, t: float) -> float:
    return a * (1 - t) + b * t


def dot3(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def smoothstep(edge0, edge1, x):
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)


def smoothstep_r(edge0, edge1, x):
    return 1.0 - smoothstep(edge1, edge0, x)


def softbox(direction, centre, half, softness, tilt):
    c = normalise(centre)
    f = dot3(direction, c)
    if f <= 0.05:
        return 0.0
    up = (0.0, -1.0, 0.0) if abs(c[1]) < 0.92 else (1.0, 0.0, 0.0)
    u = normalise(cross(up, c))
    v = cross(c, u)
    proj = (dot3(direction, u) / max(f, 0.25), dot3(direction, v) / max(f, 0.25))
    ct, st = math.cos(tilt), math.sin(tilt)
    proj = (ct * proj[0] - st * proj[1], st * proj[0] + ct * proj[1])
    q = (abs(proj[0]) - half[0], abs(proj[1]) - half[1])
    distance = math.hypot(max(q[0], 0.0), max(q[1], 0.0)) + min(max(q[0], q[1]), 0.0)
    return 1.0 - smoothstep(-softness, softness, distance)


def normalise(v):
    length = math.sqrt(dot3(v, v)) or 1.0
    return (v[0] / length, v[1] / length, v[2] / length)


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def outer_studio(direction, jewel, detail):
    d = normalise(direction)
    up_fade = smoothstep_r(0.9, -0.9, d[1])
    base_room = [mix(0.020, jewel[i] * 0.14, 0.42) * (0.65 + 0.55 * up_fade) for i in range(3)]
    floor_bounce = max(0.0, min(1.0, d[1])) ** 2.2
    col = [base_room[i] + jewel[i] * (0.42 * floor_bounce) for i in range(3)]
    key_main = softbox(d, (-0.60, -0.74, -0.30), (0.70, 0.155), 0.090, -0.52)
    col = [c + key_main * 13.0 for c in col]
    if detail > 0.5:
        key_rim = softbox(d, (-0.24, -0.76, -0.60), (0.70, 0.095), 0.075, -0.22)
        side_glow = max(0.0, min(1.0, 1.0 - abs(d[2]))) ** 1.8 * (0.55 + 0.45 * smoothstep_r(0.6, -0.7, d[1]))
        col = [c + key_rim * 8.0 + mix(jewel[i], (0.95, 1.0, 1.0)[i], 0.48) * (side_glow * 1.15)
               for i, c in enumerate(col)]
    return tuple(col)


def inner_studio(position, direction, jewel, is_tir, bottom_rel, detail):
    d = normalise(direction)
    up_fade = smoothstep_r(1.0, -1.0, d[1])
    col = [mix(0.022, jewel[i] * 0.22, 0.55) * (0.65 + 0.50 * up_fade) for i in range(3)]
    if detail > 0.5 and d[1] > -0.05:
        t_floor = max(0.0, min(260.0, (bottom_rel - position[1]) / max(d[1], 0.08)))
        fx, fz = position[0] + d[0] * t_floor, d[2] * t_floor
        r2 = (fx * fx + fz * fz) / (50.0 * 50.0 * 0.60)
        pool = math.exp(-r2 * 0.85)
        core = math.exp(-r2 * 2.4)
        fade = smoothstep(-0.05, 0.42, d[1])
        col = [c + jewel[i] * (1.05 * pool + 0.48 * core) * fade for i, c in enumerate(col)]
    lobes = [
        (pow(max(0.0, dot3(d, normalise((-0.55, -0.72, -0.42)))), 3.2), 1.45),
        (pow(max(0.0, dot3(d, normalise((0.82, -0.25, -0.52)))), 3.6), 1.15),
        (pow(max(0.0, dot3(d, normalise((-0.88, 0.12, -0.46)))), 3.4), 1.05),
        (pow(max(0.0, dot3(d, normalise((0.05, -0.92, -0.38)))), 3.0), 1.10),
    ]
    total = sum(value * weight for value, weight in lobes)
    boost = mix(0.92, 1.22, 1.0 if is_tir else 0.0)
    return tuple(c + mix(jewel[i], 1.0, 0.52) * total * boost for i, c in enumerate(col))


def glass_plate(uv, jewel, detail):
    top = max(0.0, min(1.0, 0.5 - 0.5 * uv[1])) ** 0.85
    col = [mix(0.120, 0.700, top), mix(0.126, 0.740, top), mix(0.140, 0.840, top)]
    col = [c * mix(1.0, jewel[i], 0.45) for i, c in enumerate(col)]
    kx, ky = (uv[0] + 0.34) / 0.95, (uv[1] + 0.58) / 0.55
    key = math.exp(-(kx * kx + ky * ky) * 1.35) * 13.0 * 0.055
    col = [c + key for c in col]
    if detail > 0.5:
        strip = math.exp(-((uv[0] - 0.86) / 0.26) ** 2) * smoothstep_r(0.80, -0.95, uv[1])
        col = [c + (0.90, 0.96, 1.00)[i] * (strip * 1.60) for i, c in enumerate(col)]
    cx, cy = uv[0] / 0.90, (uv[1] - 0.94) / 0.34
    r2 = cx * cx + cy * cy
    pool = (1.05 * math.exp(-r2 * 0.85) + 0.48 * math.exp(-r2 * 2.4)) * 3.00
    return tuple(c + jewel[i] * pool for i, c in enumerate(col))


def shade(surface_numbers, point):
    """One pixel of `hermeyGlassBody`, with the mask's distance field computed here."""
    half_w, half_h = surface_numbers["half"]
    centre = surface_numbers["centre"]
    rxy, rz = surface_numbers["rxy"], surface_numbers["rz"]
    half_depth = surface_numbers["halfDepth"]
    detail = surface_numbers["detail"]
    side = surface_numbers["size"]
    rim_gain, exposure, absorption = 1.25, 1.0, 1.0

    signed, inland = distance_to_outline(point, surface_numbers["outline"])
    coverage = 1.0 if signed >= 0 else 0.0
    inset = max(signed, 0.0)
    outside = max(-signed, 0.0)

    # `pow(tint, 2.2)` — sRGB in, linear optics, gamma out.
    tint = tuple(c ** 2.2 for c in TINT)
    max_c, min_c = max(tint), min(tint)
    saturation = (max_c - min_c) / max_c if max_c > 0.001 else 0.0
    pure_hue = tuple(c / max_c for c in tint) if max_c > 0.05 else (0.88, 0.94, 0.97)
    jewel = tuple(mix((0.88, 0.94, 0.97)[i], pure_hue[i], min(1.0, saturation * 1.08)) for i in range(3))
    trans = tuple(mix(0.97, jewel[i], min(1.0, saturation * 0.88)) for i in range(3))
    sigma = tuple(-math.log(max(c, 0.12)) * 0.62 + 0.08 for c in trans)

    # The normal, from the field's gradient and the height profile's own slope.
    dh = 0.0
    if inset < rxy and rz > 0.0:
        k = 1.0 - inset / rxy
        dh = rz * k / (rxy * math.sqrt(max(1e-3, 1.0 - k * k)))
    normal = normalise((dh * inland[0], dh * inland[1], 1.0))
    cos_yaw, sin_yaw = math.cos(REST_YAW), math.sin(REST_YAW)
    cos_pitch, sin_pitch = math.cos(REST_PITCH), math.sin(REST_PITCH)
    nx, ny, nz = normal
    screen = (cos_yaw * nx + sin_yaw * nz,
              sin_yaw * sin_pitch * nx + cos_pitch * ny - cos_yaw * sin_pitch * nz,
              -sin_yaw * cos_pitch * nx + sin_pitch * ny + cos_yaw * cos_pitch * nz)
    cos1 = max(0.0, min(1.0, screen[2]))
    f1 = 0.04 + (1 - 0.04) * (max(0.0, min(1.0, 1 - cos1)) ** 5)

    height = half_depth if (rxy <= 0.0 or inset >= rxy) else \
        half_depth - rz + math.sqrt(max(0.0, 1.0 - (1.0 - max(0.0, inset) / rxy) ** 2)) * rz
    thick = max(0.0, min(1.0, height / max(half_depth, 0.001)))

    rd = (0.0, 0.0, -1.0)
    n1 = normalise((screen[0], screen[1], max(screen[2], 0.02)))
    reflected = (rd[0] - 2 * dot3(rd, n1) * n1[0],
                 rd[1] - 2 * dot3(rd, n1) * n1[1],
                 rd[2] - 2 * dot3(rd, n1) * n1[2])
    accum = [c * f1 for c in outer_studio(reflected, jewel, detail)]

    # The hood: the key's own reflection, in the body's plane.
    hood_p = ((point[0] - centre[0]) / max(half_w, 0.5) + 0.36,
              (point[1] - centre[1]) / max(half_h, 0.5) + 0.50)
    ct, st = math.cos(-0.42), math.sin(-0.42)
    hood = ((ct * hood_p[0] - st * hood_p[1]) / 0.46, (st * hood_p[0] + ct * hood_p[1]) / 0.105)
    hood_distance = math.hypot(max(abs(hood[0]) - 1.0, 0.0), max(abs(hood[1]) - 1.0, 0.0))
    hood_value = 1.0 - smoothstep(-0.04, 0.12, hood_distance)
    accum = [c + hood_value * 1.9 * (0.45 + 0.55 * (1.0 - thick)) for c in accum]

    weight = 1.0 - f1
    unit = max(side, side) / 100.0
    half_depth_u = half_depth / max(unit, 0.0001)

    # Refraction: Snell, then the body's own optical distance.
    cos_i = dot3(rd, n1)
    k = 1.0 - (1.0 / 1.50) ** 2 * (1.0 - cos_i * cos_i)
    if k < 0:
        refracted = reflected
        tir = True
        optical = 0.42
    else:
        refracted = (1.0 / 1.50) * rd[0] - ((1.0 / 1.50) * cos_i + math.sqrt(k)) * n1[0], \
                    (1.0 / 1.50) * rd[1] - ((1.0 / 1.50) * cos_i + math.sqrt(k)) * n1[1], \
                    (1.0 / 1.50) * rd[2] - ((1.0 / 1.50) * cos_i + math.sqrt(k)) * n1[2]
        tir = False
        total_path_u = (2.0 * half_depth_u) / max(0.30, cos1)
        ref_scale = max(half_depth_u * 2.2, 14.0)
        optical = total_path_u / (ref_scale + total_path_u * 0.30)
        norm = math.sqrt(dot3(refracted, refracted)) or 1.0
        refracted = tuple(c / norm for c in refracted)
    exit_dir = reflected if tir else (refracted[0], refracted[1], -abs(refracted[2]))

    travel = (max(-8.0, min(8.0, refracted[0] * (2.0 * half_depth * 1.6 / max(0.35, cos1)))),
              max(-8.0, min(8.0, refracted[1] * (2.0 * half_depth * 1.6 / max(0.35, cos1)))))
    uv = ((point[0] - centre[0]) / max(half_w, 0.5) * mix(0.94, 0.76, thick) + travel[0] / max(half_w, 0.5),
          (point[1] - centre[1]) / max(half_h, 0.5) * mix(0.94, 0.76, thick) + travel[1] / max(half_h, 0.5))
    plate = glass_plate(uv, jewel, detail)

    beer = tuple(math.exp(-sigma[i] * (optical * (0.30 + 0.60 * thick))) for i in range(3))
    through = [plate[i] * beer[i] * mix(1.15, 0.78, thick) for i in range(3)]
    internal = inner_studio(((point[0] - centre[0]) / max(unit, 0.0001),
                             (point[1] - centre[1]) / max(unit, 0.0001), 0.0),
                            exit_dir, jewel, 1.0 if tir else 0.0,
                            max(half_h, 0.5) / max(unit, 0.0001), detail)
    through = [through[i] + internal[i] * (0.24 + 0.36 * thick) for i in range(3)]
    accum = [accum[i] + through[i] * weight for i in range(3)]

    rim_width = max(1.0, 0.035 * max(side, side))
    rim_band = 1.0 - smoothstep(0.0, rim_width, inset)
    rim_dir = normalise((-0.55, -0.80, 0.0))
    facing = 0.62 + 0.38 * max(0.0, min(1.0, (screen[0] * rim_dir[0] + screen[1] * rim_dir[1]) * 0.5 + 0.5))
    rim_light = tuple(mix(jewel[i], (0.95, 1.0, 1.0)[i], 0.55) for i in range(3))
    accum = [c + rim_light[i] * (rim_band * (0.55 + surface_numbers["rim"] * rim_gain)) * facing
             for i, c in enumerate(accum)]

    inner_line = 1.0 - smoothstep(rim_width * 0.25, rim_width * 0.90, abs(inset - rim_width * 1.70))
    accum = [c + mix(jewel[i], 1.0, 0.70) * (inner_line * 0.95) for i, c in enumerate(accum)]

    accum = [c * exposure for c in accum]
    peak = max(accum)
    if peak > 0.0001:
        mapped = peak / (1.0 + peak * 0.48)
        accum = [c * (mapped / peak) for c in accum]
        white_roll = smoothstep(2.2, 5.2, peak)
        accum = [mix(accum[i], mapped, white_roll * 0.80) for i in range(3)]

    lum = max(accum)
    edge_transparency = mix(0.36, 0.68, (max(0.0, min(1.0, 1 - cos1))) ** 1.55)
    alpha = max(0.34, min(0.97, edge_transparency * 1.15
                           - 0.08 * weight
                           + 0.34 * smoothstep(0.30, 0.95, lum)
                           + 0.30 * rim_band))
    alpha *= coverage

    colour = tuple(max(0.0, min(1.0, c)) ** (1 / 2.2) for c in accum)

    # The contact shadow and the caustic, over the page.
    shadow_p = math.hypot((point[0] - centre[0]) / max(half_w * 0.86, 0.5),
                          (point[1] - centre[1] - half_h * 0.96) / max(half_h * 0.16, 0.8))
    shadow = max((1.0 - smoothstep(0.15, 1.0, shadow_p)) * 0.55,
                 (1.0 - smoothstep(0.0, max(1.5, 0.055 * max(side, side)), outside)) * (1.0 if outside > 0 else 0.0) * 0.30)
    caustic_p = math.hypot((point[0] - centre[0]) / max(half_w * 0.46, 0.5),
                           (point[1] - centre[1] - half_h * 1.03) / max(1.0, half_h * 0.055))
    caustic = (1.0 - smoothstep(0.10, 1.0, caustic_p)) * 0.75
    caustic_light = tuple(mix(jewel[i], (1.0, 0.92, 0.80)[i], 0.55) for i in range(3))

    premultiplied = tuple(colour[i] * alpha + caustic_light[i] * (caustic * (1.0 - alpha)) for i in range(3))
    out_alpha = max(alpha + shadow * (1.0 - alpha), caustic * (1.0 - alpha))
    over_page = tuple(premultiplied[i] + (0x0A / 255) * (1.0 - out_alpha) for i in range(3))
    # The same pixel over the raised surface: a translucent body changes with what is behind it, an
    # opaque one does not, so this pair is the translucency measured rather than asserted.
    over_surface = tuple(premultiplied[i] + (0x23 / 255) * (1.0 - out_alpha) for i in range(3))
    return {
        "inset": inset, "alpha": alpha, "colour": colour, "over": over_page,
        "overSurface": over_surface, "lum": max(over_page), "thick": thick, "f1": f1,
        "optical": optical,
    }


# ---------------------------------------------------------------- the report


def deepest_point(numbers):
    outline = numbers["outline"]
    min_x, max_x, min_y, max_y = bounds(outline)
    best = None
    for row in range(48):
        for column in range(48):
            point = (min_x + (column + 0.5) / 48 * (max_x - min_x),
                     min_y + (row + 0.5) / 48 * (max_y - min_y))
            distance, _ = distance_to_outline(point, outline)
            if best is None or distance > best[0]:
                best = (distance, point)
    return best[1]


def scanline(numbers, y, count=121):
    outline = numbers["outline"]
    min_x, max_x = bounds(outline)[0], bounds(outline)[1]
    points = [(min_x + (max_x - min_x) * i / (count - 1), y) for i in range(count)]
    return [(point, shade(numbers, point)) for point in points]


def report(side):
    numbers = surface(side)
    centre = deepest_point(numbers)
    centre_pixel = shade(numbers, centre)
    rim_width = max(1.0, 0.035 * side)
    samples = scanline(numbers, centre[1])
    inside = [(point, pixel) for point, pixel in samples if pixel["alpha"] > 0]
    # "Half way out": the pixel whose own depth is closest to half the body's deepest.
    target = 0.5 * centre_pixel["inset"]
    half_pixel = min((pixel for _, pixel in inside), key=lambda pixel: abs(pixel["inset"] - target),
                     default=centre_pixel)
    rim_pixels = [pixel for _, pixel in inside if 0.0 < pixel["inset"] <= rim_width * 0.5]
    rim_pixel = rim_pixels[-1] if rim_pixels else centre_pixel

    def line(name, pixel):
        r, g, b = (round(c * 255) for c in pixel["over"])
        straight = tuple(round(c * 255) for c in pixel["colour"])
        surface = tuple(round(c * 255) for c in pixel["overSurface"])
        return (f"  {name:<7} inset {pixel['inset']:5.2f} pt  alpha {pixel['alpha']:.3f}  "
                f"straight sRGB {straight}  over #0A0A0A {r:3d},{g:3d},{b:3d}  "
                f"over #232323 {surface[0]:3d},{surface[1]:3d},{surface[2]:3d}  luma {pixel['lum']:.3f}")

    print(f"cat / idle / {side:.0f} pt  view {side:.0f}x{side:.0f}  "
          f"body {2 * numbers['half'][0]:.1f}x{2 * numbers['half'][1]:.1f} pt  "
          f"rxy {numbers['rxy']:.2f}  rz {numbers['rz']:.2f}  halfDepth {numbers['halfDepth']:.2f}  "
          f"detail {numbers['detail']:.0f}")
    print(line("centre", centre_pixel))
    print(line("mid", half_pixel))
    print(line("rim", rim_pixel))

    # The alpha profile across the body, at the deepest row.
    columns = [inside[0], inside[len(inside) // 4], inside[len(inside) // 2],
               inside[(3 * len(inside)) // 4], inside[-1]] if inside else []
    profile = " ".join(f"{pixel['inset']:.1f}pt:{pixel['alpha']:.2f}" for _, pixel in columns)
    print(f"  alpha across the body (left → right): {profile}")

    # The interior gradient is vertical (the studio's cyclorama), so it is read down the centre.
    top, bottom = bounds(numbers["outline"])[2], bounds(numbers["outline"])[3]
    vertical = [shade(numbers, (centre[0], top + (bottom - top) * i / 8)) for i in range(9)]
    vertical = [pixel for pixel in vertical if pixel["alpha"] > 0]
    column = " ".join(f"{pixel['lum']:.2f}" for pixel in vertical)
    lift = (max(pixel["lum"] for pixel in vertical) - min(pixel["lum"] for pixel in vertical)) if vertical else 0
    print(f"  luma down the centre (top → bottom): {column}")

    print(f"  checks: centre alpha {centre_pixel['alpha']:.2f} well under 1 "
          f"{'PASS' if centre_pixel['alpha'] < 0.85 else 'FAIL'}; "
          f"rim alpha > centre {rim_pixel['alpha']:.2f} > {centre_pixel['alpha']:.2f} "
          f"{'PASS' if rim_pixel['alpha'] > centre_pixel['alpha'] else 'FAIL'}; "
          f"rim brighter than centre {rim_pixel['lum']:.2f} > {centre_pixel['lum']:.2f} "
          f"{'PASS' if rim_pixel['lum'] > centre_pixel['lum'] else 'FAIL'}; "
          f"interior gradient {lift:.2f} luma top-to-bottom "
          f"{'PASS' if lift > 0.05 else 'FAIL'}")
    print()


if __name__ == "__main__":
    for size in (24.0, 48.0, 200.0):
        report(size)
