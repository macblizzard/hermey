# Glass round 3 — where it stopped (2026-11-26)

Next worker: read this before touching the shader. The Mac went offline mid-round.

## The striping is field quantisation, not sampling

The glass6 worker eliminated the two obvious suspects with tests, in this order:

1. **Exact EDT instead of the cheap distance transform** — striping unchanged.
2. **A constant interior gradient instead of the raymarched one** — striping unchanged.

So the vertical bands are not sampling noise and not the gradient maths: they come from the mask field's
**1-px quantisation being amplified** by the interior/rim terms. Its last hypothesis, untested, was to
**smooth the field before packing it** into `RGBA16F`.

## What to try, in order

1. Smooth the distance field before packing (its own last idea). Cheap, and it addresses the mechanism.
2. If that is not enough, compute the interior terms from an analytic field evaluated per fragment rather
   than re-reading the packed 1-px mask — the banding cannot survive an analytic field.
3. Only then attempt the other two goals (interior bounce light, caustic that follows the ears). They were
   not started.

## Proof state

- Branch `fix/glass-critique` in `/root/jobs/hermey-glass6` holds whatever it committed; renders and
  `mkshader.py` / `stripes.py` / `variants/` are under `/root/jobs/glass6-proof/`.
- Measurements it took: `canvas col means sd: 0.1082`, `pattern col means sd: 0.1039` — a per-column noise
  metric, the right instrument for "are the stripes gone?". Use it again.
- My independent rating of the shipped predecessor (`/root/jobs/glass5-proof/ship/cat-idle-200pt-canvas.png`)
  was **4.5/10** against its author's 8/10. Rate renders yourself with `vision_analyze`, on the canvas render
  only (the `-pattern` render is a checkerboard by design and always looks blocky).
