# Local patches to the bundled noVNC

`@novnc/novnc` 1.7.0, unmodified **except** for the file below. Re-apply after any upgrade of the
bundle, or the Bot Computer silently mis-aims every click once the picture is zoomed.

## `core/util/element.js` — `clientToElement()`

The original returns `x - bounds.left`: CSS pixels inside the canvas's *rendered* rect. `RFB` then
feeds that to `Display.absX()`, which divides by noVNC's own scale — so any CSS transform applied by
a wrapping element (the viewer's pinch-to-zoom) is counted twice: at 2× zoom every click landed at
twice the distance from the top-left corner, and the context menu opened far from the pointer.

The patched version multiplies by `offsetWidth / bounds.width` (and the same for height). Layout
metrics ignore ancestor transforms, so the ratio undoes the zoom and is 1 when nothing is
transformed. Verified in `Tools/verify/novnc_client_to_element.mjs` — unzoomed output is identical
to upstream, and 2× zoom, 2× zoom plus pan both map exactly.
