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
| `cat-<state>-<side>pt-canvas.png` | composited over the dark theme canvas `#0A0A0A` — what a person sees |
| `cat-<state>-<side>pt-surface.png` | the same pixels over the raised surface `#232323` — the translucency proof |
| `cat-<state>-<side>pt-zoom.png` | nearest-neighbour ×N of the 24 and 48 pt cases |

It also prints, per case, `cover` (pixels the body covers), `mean` and `max` alpha inside the
silhouette. Two composites are the point: a translucent body changes with what is behind it, an
opaque one does not.

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
`BotAvatarGlassSurface.make` and the fragment, and computes the distance field exactly against the
outline's segments instead of chamfering a raster. `Tests/test_avatar_glass_shader.py` pins the
literals both sides use, so the mirror cannot drift from the shader silently.

Known differences, so nobody reads more into the numbers than is there: the mirror flattens the
authored path (the preset is softened with a 5 % fillet on sharp corners), holds the idle pose, and
does not model the texture's 8-bit quantisation of the distance field.
