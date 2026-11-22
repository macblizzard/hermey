# A2UI migration — and how to go back

Native agent-driven UI replacing the `::blocks` WebView path. Three pieces, none of them
irreversible, and a rollback that is configuration only.

## What is where

| Layer | Piece | Rollback |
|---|---|---|
| Agent | `hermes-a2ui` plugin (`/root/.hermes/plugins/hermes-a2ui`) — compiles A2UI Express with the pinned SDK, validates against the Basic catalog, writes `::a2ui{…}` markers | remove it from `plugins.enabled` |
| Agent | `hermes-genui` plugin — **untouched and still enabled** | nothing to do |
| Client | `Sources/HermesA2UI` — decodes the inline surface, draws it with `A2UISwiftUI` | `defaults write dev.hermey.app a2ui.surfaces.disabled -bool YES` |
| Client | transcript both platforms — A2UI branch first, `::blocks` branch still compiled | same defaults key |
| Client | `HermesKit/GenUIBlocks.swift` — the `::blocks` + WebView card path | **kept**; it is the fallback while A2UI coverage grows |

The surface rides inside the message (`::a2ui{"surface":…,"messages":[…]}`), so a transcript
reopened later still draws: no card session, no bridge fetch, nothing to expire.

## Turning A2UI on

1. Ship a client built after the wiring (macOS + iOS both compile with `HermesA2UI`; CI's Apps
   job is the proof). An older build shows the marker as raw text, so the order matters.
2. `/root/.hermes/config.yaml` → `plugins.enabled`: add `hermes-a2ui`, remove `hermes-genui`.
3. Restart the engine (the plugin registers a tool and a hook at startup).
4. `hermes plugins list` shows `hermes-a2ui`; a drawing turn carries `::a2ui{ … }`.

## Rolling back (target: under a minute, no data loss)

Either half alone is a complete rollback of drawing:

- **Client only, no rebuild:** `defaults write dev.hermey.app a2ui.surfaces.disabled -bool YES`
  — every reply falls back to the `::blocks` WebView card.
- **Server only:** `plugins.enabled`: remove `hermes-a2ui`, add `hermes-genui` back; restart.
- **Both:** as above, and `git checkout genui-baseline-20261121` for the client.

Nothing in SQLite, no migration, no board data touched.

## Verified so far

- Plugin: 13 behavioural checks against the real SDK (`tests/test_plugin.py`), including a
  validator refusal naming the allowed values.
- Loading: Hermes' own `plugins validate` passes (capability probe ran `register()`), and the
  plugin manager reports `tools: 1, hooks: 1, error: None`.
- Hook dispatch through `PluginManager.invoke_hook`: `local` → inline wire JSON,
  `telegram` → Markdown, no marker left behind.

## Known gaps before this can replace genui

1. **Actions** — a tapped `Button` is not sent back yet (`outboundListener` +
   `ActionHandling`); the SDK API is identified, the send path is not wired. Cards draw, buttons
   are inert.
2. **Coverage** — the Basic catalog is 18 components; `hermes-genui` had 36 blocks. Charts,
   tables as a type, timelines, flows and calculators need a custom Hermey catalog before
   `hermes-genui` can be deleted rather than disabled.
3. **Seen on a screen** — the wiring compiles and both apps build on CI, but no surface has been
   drawn in front of a human yet. That is the trial.
