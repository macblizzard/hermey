# Parked: backdrop refraction (glass sampling the page behind it)

Status: **parked by Mo on 2026-11-27**, not merged, not in any release.

- Branch: `fix/glass-transmission` @ `52c072b` ("glass: refract the app's own page behind the body"),
  plus its ship-first parent `6c79e4b` (that half **is** shipped — it became 0.1.685/0.1.686).
- Worktree on this host: `/root/jobs/hermey-glass8` (may be pruned; recreate from the branch).
- Proof images: `/root/jobs/glass8-proof/final/cat-idle-200pt-page.png` (after) and
  `-page-studio.png` (before), also published at
  `https://hermes.corvus-vibes.ts.net:9446/cody/2026-11-27-glass-backdrop-*.png`.

## Why it is parked rather than merged

The branch is a **competing rewrite of the same shader**, not a patch: it renames the interior entry
point (`sampleGlassPlate` → `sampleBehind(pagePoint, plateUV, …, pageKnown)`) and changes the plate, the
12-slice loop, the back-wall mirror and the focus term. Merging it today conflicts in
`Tools/glass-proof/numbers.py` and `Tests/test_avatar_glass_shader.py`, and taking it wholesale would
**drop the brightness and glow material that shipped in 0.1.687** (Mo approved that look).

## What it does, and what it measured

- `GlassBackdrop.capture` renders the window's content view around the body (0.85 body-width margin),
  hides the body's own layer for one synchronous draw, uploads `rgba8Unorm` **with a mip chain**.
- Taken in `refreshPage` — on a move of the body's box, or staleness ≥ 0.5 s. Never in `draw`.
- The interior samples the ray's own landing on the page, so an edge behind the avatar arrives displaced.
- Measured: ray lands **24.4 pt** from the pixel on average, up to **80.9 pt**. Centre luminance with the
  snapshot: pane +0 %, control −11 %, busy page −19 % (vs +148 % for the no-page fallback).
- Honest limit it reported itself: the page folds where the 2.5-D normal is piecewise, and the body dims
  what it transmits, so the bend is plain in the UV map and subtle in a 400 px render.

## To resume

Re-author it **on top of** the current material rather than merging the branch: keep `kSelfLightLevel`,
`kGlowRadius`, `kGlowStrength` and the page-luminance mix from 0.1.687, and add the backdrop as one extra
source that the existing terms sample — then re-render the four surfaces (pane, #2B2B2B, light page, busy
page) and re-rate them before it goes near a build. Only a device can settle whether SwiftUI's hosting
view answers `cacheDisplay`/`layer.render`; if it refuses, the fallback ladder (snapshot → flat page
colour → studio) must keep the shipped look.
