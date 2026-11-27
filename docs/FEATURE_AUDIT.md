# Feature audit — bug hunt board (2026-11-27)

One row per area. A worker reviews the area, appends its findings under its heading with `path:line`,
severity (`high` / `medium` / `low`), what is actually wrong, and the one-line fix. Findings only — fixes
land in a second pass so the board stays readable.

Status: ⏳ reviewing · ✅ clean · ⚠️ findings

| area | status | high | medium | low |
|---|---|---|---|---|
| voice — capture, VAD, endpoint, stop phrase, playback | ⏳ | – | – | – |
| attachments — upload, host route, rendering | ⏳ | – | – | – |
| updates — feed, offer, prompt, appcast, host self-update | ⏳ | – | – | – |
| chat — paging, scroll, clamp, archive/roll, cache | ⏳ | – | – | – |
| relay — sessions, pairing, bot-chat ownership | ⏳ | – | – | – |
| faces — avatars, glass, pets, live activity, widgets | ⏳ | – | – | – |
| compose — composer, shortcuts, settings, cards/genui | ⏳ | – | – | – |

## Findings

### voice
_(append below)_

### attachments
_(append below)_

### updates
_(append below)_

### chat
_(append below)_

### relay
_(append below)_

### faces
_(append below)_

### compose
_(append below)_

## Result of the review pass (7 areas, all reported)

| area | high | medium | low | worst finding |
|---|---|---|---|---|
| voice | 3 | 6 | 6 | barge-in re-trips every 30 ms block and re-seeds the capture, truncating the question to its last 1.2 s |
| attachments | 1 | 4 | 10 | disk cache keyed by bare file name: same name in two profiles serves the wrong bytes |
| updates | 1 | 6 | 10 | iOS feed dies whenever a `hermeyd` release is newest (`releases/latest` has no altstore.json), so the check degrades silently |
| chat | 1 | 3 | 6 | the generation guard is dead code, so a decorated transcript is classified unchanged and sent pictures never appear |
| relay | 1 | 4 | 6 | `pair_start`/`pair_claim` gate on loopback only, which is true for every request through `tailscale serve` — a remote peer with tailnet access can mint and claim a pairing code |
| faces | 2 | 3 | 4 | the desktop pet's drawn avatar is frozen at the rest pose (no SwiftUI scene → `scenePhase` reads `.background`) |
| compose | 1 | 4 | 12 | `send()` sets `sending` only after a truncate round-trip, so a second ⌘↩ duplicates the message |

Full reports: `2026-11-27-voice.md`, `-attachments.md`, `-updates.md`, `-chat.md`, `-relay.md`, `-faces.md`, `-compose.md`
(served alongside this board).

## Fix pass

Ordered by severity; each fix lands with a test that fails without it.
