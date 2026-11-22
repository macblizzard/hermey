# A2UI migration — and how to go back

Native agent-driven UI replacing the `::blocks` WebView path. Three pieces, none of them
irreversible, and a rollback that is configuration only.

## What is where

| Layer | Piece | Rollback |
|---|---|---|
| Agent | `hermes-a2ui` plugin (`/root/.hermes/plugins/hermes-a2ui`) — compiles A2UI Express with the pinned SDK, validates against the Basic catalog, writes `::a2ui{…}` markers | remove it from `plugins.enabled` |
| Agent | `hermes-genui` plugin — **untouched and still enabled** | nothing to do |
| Client | `Sources/HermesA2UI` — decodes the inline surface, draws it with `A2UISwiftUI` | not referenced by the app shells yet |
| Client | `HermesKit/GenUIBlocks.swift` — the `::blocks` + WebView card path | **kept**; it is the fallback while A2UI coverage grows |

The surface rides inside the message (`::a2ui{"surface":…,"messages":[…]}`), so a transcript
reopened later still draws: no card session, no bridge fetch, nothing to expire.

## Turning A2UI on

1. `/root/.hermes/config.yaml` → `plugins.enabled`: add `hermes-a2ui`, remove `hermes-genui`.
2. Restart the engine (the plugin registers a tool and a hook at startup).
3. `hermes plugins list` shows `hermes-a2ui`; a drawing turn carries `::a2ui{ … }`.

## Rolling back (target: under a minute, no data loss)

1. `plugins.enabled`: remove `hermes-a2ui`, add `hermes-genui` back.
2. Restart the engine. `::blocks` cards draw again — the client path was never removed.
3. Client, if a release already shipped `HermesA2UI`: `git checkout genui-baseline-20261121`.

Nothing in SQLite, no migration, no board data touched: `hermes-genui`'s boards were never
modified, and A2UI surfaces live in the message text.

## Verified so far

- Plugin: 13 behavioural checks against the real SDK (`tests/test_plugin.py`), including a
  validator refusal naming the allowed values.
- Loading: Hermes' own `plugins validate` passes (capability probe ran `register()`), and the
  plugin manager reports `tools: 1, hooks: 1, error: None`.
- Hook dispatch through `PluginManager.invoke_hook`: `local` → inline wire JSON,
  `telegram` → Markdown, no marker left behind.

## Known gaps before this can replace genui

1. **Client wiring** — `A2UISurfaceView` is not yet used by the transcript renderer, so nothing
   draws natively until `HermesRender`/the app shell calls it for a message that has a surface.
2. **Actions** — a tapped `Button` is not sent back yet (`outboundListener` +
   `ActionHandling`); the SDK API is identified, the send path is not wired.
3. **Coverage** — the Basic catalog is 18 components; `hermes-genui` had 36 blocks. Charts,
   tables as a type, timelines, flows and calculators need a custom Hermey catalog before
   `hermes-genui` can be deleted rather than disabled.
4. **Build** — the Swift target has never been compiled (no toolchain on the Linux box). The
   dependency needs a Swift 6.1 toolchain; `Package.swift` here is `5.9`. First build decides
   whether the manifest needs bumping.
