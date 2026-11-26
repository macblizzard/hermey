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
**working**, over the app's own two passes — the Metal body, then the `Canvas`
that draws the eyes and the marks on top of it (`ImageRenderer`, the route
`BotAvatarIcon` takes for a still) — and writes, per case:

| file | what it is |
| --- | --- |
| `cat-<state>-<side>pt-canvas.png` | composited over the dark theme canvas `#0A0A0A` — what a person sees |
| `cat-<state>-<side>pt-surface.png` | the same pixels over the raised surface `#232323` — the translucency proof |
| `cat-<state>-<side>pt-pattern.png` | the **refraction proof**: the same pass over a checkerboard |
| `cat-<state>-<side>pt-zoom.png` | nearest-neighbour ×N of the 24 and 48 pt cases |

The four surfaces a face is judged on are `-pane` (the bot list), `-ctrl` (`#2B2B2B`, one step up, so
a body tuned to a single number cannot pass), `-lit` (the light page `#F2F2F2`) and `-busy` (a
generated page of rows, captions and separators — a face that reads on a flat pane and disappears
among text has not been fixed).

It also prints, per case, `cover` (pixels the body covers), `mean` and `max` alpha inside the
silhouette, and the numbers behind the picture: the body's relative luminance against each page,
its hue and chroma, and the eye ink's contrast against it. Those are read off the same frame with the
features *left out* — the eyes are opaque ink exactly where the body is measured — while the pictures
carry the face.

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

## `numbers.py` — the arithmetic (needs nothing)

```sh
python3 Tools/glass-proof/numbers.py
```

A mirror of the fragment, evaluated on the CPU, for when there is no Mac: it prints the RGBA at the
body's **centre**, **mid** and **rim** at 24, 48 and 200 pt (straight, over `#0A0A0A`, and over
`#232323`), the alpha across the body, the luma down its centre, and PASS/FAIL for the four claims
that matter — the centre is translucent, the rim is more opaque than the centre, the rim is brighter
than the centre, and the interior has a gradient.

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
