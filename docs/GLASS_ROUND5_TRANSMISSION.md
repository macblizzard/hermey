# Glass round 5 — the body transmits the page (2026-11-26)

Two commits, on purpose: the safe half ships first, the half with architectural risk is its own commit
and its own guards, and either can be taken without the other.

## The two reviews, and what they said

Two independent readings of the render 0.1.683 would have shipped agreed on one thing: the body is too
opaque. Canvas 5.5/10, app surface 6/10, and both in the same words — "the body is only translucent at
the very outer edges; the central body is incredibly dense … more like gummy candy, polished stone, or
acrylic than true glass". The worker added the second half: "what refracts through it is a synthetic
cyclorama — no structured background to bend".

Measured before this round, over the app's own pane (`#1E1E1E`), the body's centre sat at **0.310
against the pane's 0.118 — 163 %**. That is a block, and the number says so without an adjective.

## SHIP-FIRST — `glass: the body transmits the page it is drawn on, and is brighter for it`

The body carries the page's own light, and the absorption is a tint's.

* `BotAvatarGlassSurface.page(for:)` names the surface an avatar is drawn over, from the theme's own
  tokens — `Theme.dark.surface` `#232323`, `Theme.light.surface` `#F0EEE6`. A surface that cannot know
  its page (the desktop pet, over a wallpaper) answers `.zero`, and the body it gets is exactly the
  body 0.1.683 shipped.
* The fragment transmits it: the plate, the interior's twelve slices, the back wall's reflection and
  the internal focus all take the same colour, so the body's light has one source.
* The absorption gain drops 0.62 → 0.40 with a 0.045 floor (opacity 0.45 → 0.26): the 200 pt path
  passes **94 / 55 / 31 %** instead of 90 / 32 / 19. The body is brighter *because more of the page's
  light gets through it* — nothing was added to it.
* The invented studio is scaled by the page's own light. The front face's 13.0-softbox key was nine
  times the pane's luminance on its own, which is what made the body a lit object with nothing behind
  it. The bounce gain goes 1.05 → 1.35.

Measured, centre and mid-ring (`Tools/glass-proof/numbers.py`, 200 pt; the rendered proof agrees
within 0.01):

| surface | centre | ring | before |
|---|---|---|---|
| pane `#1E1E1E` | 0.129 (+10 %) | 0.125 (+6 %) | +163 % |
| control `#2B2B2B` | 0.160 (−5 %) | 0.155 (−8 %) | +106 % |
| lit `#F2F2F2` | 0.785 (−17 %) | 0.769 (−19 %) | −28 %, and dimmer (0.69) |

The eyes: the ink is opaque `.082`, so the body can only move away from it — **1.13:1** against the
pane (both are near-black there, by construction) and **10.9:1** against the lit surface, up from
9.0:1. Nothing is washed out, and no term was added to lift the face.

Honest limit: on a *dark* pane a body that transmits the pane cannot be brighter than the pane, so
"brighter" is relative to the body it replaces — the centre is the page's own light, the ring is 1.7×
the centre, and on a light surface the whole body is bright. That is the physics, not a tuning choice.

## BACKDROP — `glass: refract the app's own page behind the body`

The plate is no longer a studio painted inside the shader. It is a picture of the app's own region
behind the avatar:

* `GlassBackdrop.capture` renders the window's content view around the body (0.85 of a body-width of
  margin, so a shoulder's ray has somewhere to land), hides the body's own layer for the length of one
  synchronous draw so the snapshot cannot contain the glass it will be refracted through, and uploads
  it as `rgba8Unorm` with a mip chain.
* The drawer takes it in `refreshPage` — on a move of the body's box in the window, or when the page
  has not been read for `GlassBackdrop.refreshInterval` (0.5 s). **Never in `draw`**, and a resize
  invalidates the frame rather than reusing it at the wrong scale.
* The fragment samples it at the coordinate the traced ray leaves the glass at:
  `land = exitPoint.xy + leaving.xy · travel`, into the page's own points (`pagePoint = centre +
  fold(land)`). Inside the total-internal-reflection band nothing leaves, so the ray's walk through the
  body is the whole displacement — using the reflected direction there puts the page where the ray
  never went, which is a torn ring at the band's edge (measured, then fixed).
* Three rungs, one function (`sampleBehind`): **snapshot** → **the flat page colour** (a host that
  cannot snapshot still gets the transmission) → **the studio plate** (the pet, the Live Activity, the
  proof's own fallback case). `kBackdropPage` lets the proof draw the bottom rung from the same string.

Measured, 200 pt, with `bend.py` as the instrument. The decisive one is `--uv`: the proof draws a
*coordinate map* (`kPageDebug`), every pixel of the body carrying the place in the page its ray landed
on, and the script decodes it and subtracts the pixel's own position. No feature detection, nothing for
an eye to recognise:

* **the traced ray lands 24.4 pt from the pixel on average, up to 80.9 pt**, over the 36 871 px the
  body covers. A flat body writes zero everywhere: the page genuinely moves under the glass.
* a horizontal bar's row moves **17 pt across the body**, at **0.5 pt per column**
  (`bend.py <png> 200 --bar 0.415`). Its edge detection is confused where a vertical rule crosses the
  same column — 35 pt with a 25 pt step is the rule, not the bar — so this mode is the corroborating
  one and `--uv` is the measurement of record;
* the page's vertical rule moves **−8.1 … +7.4 pt** across the body, at **0.78 pt per row**
  (`bend.py <png> 200 --rule 0.55`) — the lateral half of the bend, which a horizontal bar cannot show,
  and the reason the proof's page carries two vertical rules of its own.

What the eye sees at 400 px is weaker than the numbers, and that is honest: the body dims the page it
transmits (that is what a tint does), so the displacement is plain in the map and subtle in the picture.
Over a page with stronger contrast — real text at 3× — the displacement is 3× the pixels.

Centre luminance over the same surfaces with the snapshot bound: pane **+0 %**, control −11 %, busy page
−19 %, against **+148 %** for the no-page fallback.

Honest limits, in order of how visible they are:

* the page's image **folds** where the 2.5-D normal is piecewise — the silhouette's medial axis. The
  mip chain blurs the fold (a compressed band blurs like a camera's); it does not remove it, and on one
  row of the proof's page it is a 15 pt step. A real lens's caustic fold is also a hard line.
* the snapshot lands in the avatar's sibling `Canvas` drawings (the ribbons behind the body belong
  there; the marks over it are a small artifact) — there is no way to name a host's layers from here.
* only the *default* theme's surfaces are named in the flat rung; a theme with a different canvas is a
  few points off in the transmitted colour.

## Cost

* SHIP-FIRST: nothing per frame. One extra `float4` of uniforms.
* BACKDROP: one capture per move (a crop of the content view, an 8-bit RGBA copy, one upload with its
  mip chain) at most twice a second — milliseconds, on the main thread, against a body redrawn at
  10 Hz. Per fragment: **one** extra texture tap when a snapshot is bound (zero when it is not), and
  the interior's twelve slices reuse that one sample rather than adding twelve.
* Mask build unchanged: 7.2–8.0 s at 800×800 under `-Onone`, 0.4 s at 96 pt, 0.1 s at 48 pt.

## What only a device can confirm

That the snapshot returns the app's own pixels at all. `NSView.cacheDisplay(in:to:)` and
`CALayer.render(in:)` are the documented ways to render a host's hierarchy, but SwiftUI's hosting views
are not guaranteed to answer them, and nothing offscreen can try. If a host refuses, the answer is the
flat page colour (the SHIP-FIRST body) and the only loss is the bend — by construction, not by luck.
Also: the real cost of a capture on a large window, the fold's visibility at 3× on a phone, and
ProMotion's pose changes against a 0.5 s refresh.
