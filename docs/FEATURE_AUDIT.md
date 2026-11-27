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

## Fix pass — shipped in 0.1.698 + hermeyd 0.8.28

| # | finding | fixed in | proof |
|---|---|---|---|
| 1 | voice: barge-in fired ~33×/s and re-seeded the capture | `fix/audit-voice` | latch + one-trip test, red-proofed (10 failures on baseline) |
| 2 | voice: a completion could be spoken for the wrong turn | `fix/audit-voice` | session-conditioned completion, red-proofed |
| 3 | voice: abandoned start tore down the next conversation | `fix/audit-voice` | start epoch checked at every await, red-proofed |
| 4 | chat: dead generation guard hid decorated rows (lost pictures) | `fix/audit-chat-compose` | generation threaded + behavioural adopt test |
| 5 | compose: Send could double-fire | `fix/audit-chat-compose` | claims the turn before the first await, concurrent-send test |
| 6 | compose: Mac could not send attachment-only | `fix/audit-chat-compose` | passes `hasAttachments` like the phone |
| 7 | compose: bare slash commands dead-looped | `fix/audit-chat-compose` | `nativeActions` set, falls through to send |
| 8 | chat: delete in the paged half stayed on screen | `fix/audit-chat-compose` | retired row removed before merge |
| 9 | updates: iOS feed 404s when a hermeyd release is latest | `fix/audit-updates` | Pages document first, release asset fallback |
| 10 | updates: host "Try again" installed then reported failure | `fix/audit-updates` | failure phase is retryable |
| 11 | updates: manual check hid behind Settings | `fix/audit-updates` | joins in-flight check and surfaces its card |
| 12 | host: state write after binary swap | `fix/audit-updates` | state written first, refuses to swap otherwise |
| 13 | relay: proxied pairing could mint a code | `fix/audit-relay` | proxy headers refused for mint, attack-chain test |
| 14 | relay: engine token in the dial log | `fix/audit-relay` | scrubbed, test asserts absence |
| 15 | relay: socket racing a revoke stayed open | `fix/audit-relay` | revoked registry, closes 4403 |
| 16 | attachments: byte cache keyed by name | `fix/audit-relay` | keyed by profile + reference |
| 17 | faces: pet avatar frozen at rest pose | `fix/audit-faces` | motion gate by host, pet passes it |
| 18 | faces: glass body never shrank under a mark | `fix/audit-faces` | route refuses glass for marks + body transform |
| 19 | faces: glass silhouette frozen at first pose | `fix/audit-faces` | silhouette key from the pose |

Not fixed, documented: Mac Sparkle installs cannot pass the signature check while the build is ad-hoc signed
(`docs/SECURITY_TASKS.md`). Med/low items not in the table above remain open in each area report.
