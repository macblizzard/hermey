# glass-proof

Two ways to look at the avatar's glass body without launching the app, and without a screenshot loop.

Neither is part of the app's build: no target in `project.yml` compiles this folder, and nothing in
`Sources/` or `Apps/` refers to it (`Tests/test_avatar_glass_shader.py` refuses both).

## `render.sh` — the pictures (needs a Mac)

```sh
Tools/glass-proof/render.sh /tmp/hermey-glass-proof
```

Compiles the avatar sources the pass needs together with `main.swift` into one module, so the preview
goes through the **app's own** types: `HermeyGlassEngine.shared` (the run-time shader compile),
`BotAvatarGlassSurface.make` (the uniforms), `BotAvatarGlassDrawer.makeMask` (the silhouette and its
distance field). It renders the `cat` preset offscreen at **24, 48 and 200 pt** in **idle** and
**working**, and writes, per case:

| file | what it is |
| --- | --- |
| `cat-<state>-<side>pt-canvas.png` | composited over the dark theme canvas `#0A0A0A` |
| `cat-<state>-<side>pt-surface.png` | the same pixels over the raised surface `#232323` |
| `cat-<state>-<side>pt-pane.png` | over `#1E1E1E`, the tone a row and a header sit at — the translucency number's surface |
| `cat-<state>-<side>pt-lit.png` | over `#F2F2F2`, drawn with the light scheme's own page — the brightness number's surface |
| `cat-<state>-<side>pt-page.png` | **the acceptance picture**: the body over a busy synthetic page — pane and control colours, five rows of text-like bars, a hairline, an accent square — sampled by the traced ray |
| `cat-<state>-<side>pt-page-studio.png` | the same page behind the same pass with **no page at all** (`kBackdropPage 0` and `pageKnown 0`), i.e. the body 0.1.683 shipped: the "before" |
| `cat-<state>-<side>pt-pattern.png` | the studio plate as a checkerboard, for the ray's transform on its own |
| `cat-<state>-<side>pt-zoom.png` | nearest-neighbour ×N of the 24 and 48 pt cases |

The page is what makes the refraction legible: a flat pane proves translucency and nothing about
bending. It is handed to the shader through `GlassBackdrop.texture` — the same upload the app uses —
and mapped by the same frame the drawer writes, so the picture is of the app's own path.

It also prints, per case, `cover` (pixels the body covers), `mean` and `max` alpha inside the
silhouette. Two composites are the point: a translucent body changes with what is behind it, an
opaque one does not.

One case at a time while a target is being judged, the full grid when it is done:

```sh
Tools/glass-proof/render.sh /tmp/glass-proof --sides 200 --states idle
```

Arguments after the output directory go to the tool itself (`--sides`, `--states`, `--scale`,
`--supersample`), so a single 200 pt idle case is one `swiftc` and a few milliseconds of GPU.

`-pattern.png` is the one that shows *refraction*. The shader cannot sample what is behind the view,
so a composite of a pattern would only prove translucency; instead the tool recompiles the same MSL
string with `kPlatePattern` set to 1, which swaps the studio for a coarse checkerboard **inside the
plate** — i.e. at the far end of the traced ray. Straight cells mean the ray went through flat glass,
compressed cells mean a lens, and cells that fold back on themselves mean the ray turned over at the
wall. Everything else (absorption, the rim, the two edges) is unchanged, so the picture is this pass
with one constant different.

Every case is rendered `--supersample 2` (the default) and box-filtered down, so the silhouette, the
plate's edges and the two rim lines are antialiased in the picture. The mask the pass reads is
half-float (RGBA16F), not RGBA8: its green and blue channels are the two distance fields, so 8 bits
per channel quantised the inset to ~0.4 pt at 200 pt — coarser than a pixel — and the surface normal,
the rim's width and every gradient were read off that quantisation. The packing is written out in
`BotAvatarGlassDrawer.halfBits` rather than using `Float16`, whose conversions the x86_64 slice of
the universal build cannot use.

## `bend.py` — the bend, as a number (needs a PNG)

```sh
python3 Tools/glass-proof/bend.py /tmp/glass-proof/cat-idle-200pt-page.png 200 --bar 0.415
```

Finds one of the page's horizontal bars in every column, and reports how far its row moves inside the
body compared with where the page drew it, plus the largest step between neighbouring columns. A body
that transmits but does not bend reports `FLAT`; a lens reports the displacement and its tilt.

`--uv` is the measurement of record: it reads `-uv.png`, the pass recompiled with `kPageDebug 1` to
write *the page coordinate each pixel samples* into the colour, decodes it, and subtracts the pixel's
own position. No feature detection and nothing for an eye to recognise — at 200 pt the traced ray lands
**24.4 pt from the pixel on average, up to 80.9 pt**, and a flat body would write zero everywhere.
`--rule` measures one of the page's vertical rules; `--bar` the horizontal ones.

## `numbers.py` — the arithmetic (needs nothing)

```sh
python3 Tools/glass-proof/numbers.py
```

A mirror of the fragment, evaluated on the CPU, for when there is no Mac: it prints the RGBA at the
body's **centre**, **mid** and **rim** at 24, 48 and 200 pt (straight, over `#0A0A0A`, and over
`#232323`), the alpha across the body, the luma down its centre, and PASS/FAIL for the four claims
that matter — the centre is translucent, the rim is more opaque than the centre, the rim is brighter
than the centre, and the interior has a gradient.

It also prints `page_report`: the body's centre and mid-ring over the two surfaces an avatar is drawn
on (`#1E1E1E` and `#F2F2F2`), against the page each transmits, and the eyes' WCAG contrast against the
body — the two claims the round is judged on, as numbers.

It mirrors `bodyTransform`, `makePart`'s thickness/`partDepth`/`rxy`/`rz`, `glassProfile`,
`BotAvatarGlassSurface.make` and the fragment — including `edgeCoverage`, `bandCoverage`,
`criticalInset`, `causticLanding` and `opticalThickness` — and computes the distance field exactly
against the outline's segments instead of chamfering a raster. It reports the body's **centre**,
**mid**, the **thin** point of the left ear, and the **rim**, so the absorption gradient the pass
claims is a pair of numbers at 24, 48 and 200 pt rather than an adjective.
`Tests/test_avatar_glass_shader.py` pins the literals both sides use, so the mirror cannot drift from
the shader silently.

Known differences, so nobody reads more into the numbers than is there: the mirror flattens the
authored path (the preset is softened with a 5 % fillet on sharp corners), holds the idle pose, and
does not model the texture's 8-bit quantisation of the distance field.
