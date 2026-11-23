# Desktop pets — design

A bot can keep a small companion on the Mac's desktop: the bot's own picture, wandering a little, that
answers a question in a speech bubble when you click it. Off by default; enabled per bot in that bot's
settings; closed from its own right-click menu, which switches the setting off again.

This is a **design** — nothing here is built yet. It is written against the code as it is today, so
every claim about an existing route or file is checkable.

## What it is, precisely

| Behaviour | Detail |
|---|---|
| Where it appears | A macOS-only floating window per enabled bot, above normal windows, on every Space, visible over full-screen apps if macOS allows it. |
| What it looks like | **Only the icon.** No frame, no border, no title bar, no panel, no coloured background — a fully transparent window whose content is the bot's picture (`/v1/bot-icons/{bot}`) at ~96 pt. The desktop, the wallpaper and whatever is behind it stay visible around the icon. |
| Idle behaviour | Small random movements — a bob, a tilt, a hop, a brief wander of a few points — at random intervals (8–30 s). No pathfinding, no walking across the screen unless asked for later. |
| Click | Opens a balloon above the pet with a text field. Type a question, press Return. |
| While it works | The balloon switches to a thinking state (three dots / a pulse) until the answer arrives. |
| The answer | Replaces the thinking state in the same balloon, scrollable if long, with a Copy button. Escape or a click elsewhere dismisses it. |
| Dragging | Click and drag moves the pet anywhere; the position is remembered per bot and per display. |
| Right-click | A menu with **Close pet** (the only item in v1). Closing switches the bot's pet setting off, so the settings toggle is the way back. |
| Several pets | One window each; each has its own position, bubble and in-flight question. Ten is the practical ceiling. |

## Why this is feasible on today's code

Three things already exist and are the reason this is a UI feature rather than a protocol change:

1. **A bot's picture is served by the host.** `GET /v1/bot-icons/{bot}` returns the PNG the app already
   renders in the bot list and the settings sheet (`MacBotIconPicker.swift` fetches exactly this).
2. **A bot can be asked a question and answer it synchronously.** `POST /v1/bots/{profile}/ask`
   (`hermeyd/src/bot_message.rs`) takes `{question, from, timeout}` and answers
   `{profile, from, session_id, question, reply, answered}`. That is the pet's whole conversation model —
   no streaming, no session juggling, and a timeout returns `delivered: true, reply: null` so the pet can
   say "sent, no answer yet" instead of hanging.
3. **The app already knows how to talk to the host from outside a conversation.** `GatewayClient` has the
   ticket transport and the call sites (`EndlessSessionPointer`, `GatewayClientActor`) that `ask` slots into.

Nothing new is needed on the host. No new entitlements: a floating window and an HTTP call to the local
host are things the current unsigned build already does.

## The window must be invisible except for the icon

This is the one requirement that decides whether the feature feels like a pet or like a widget, so it is
spelled out rather than assumed:

- `NSPanel` with `styleMask` **`.borderless` + `.nonactivatingPanel`** — a borderless window has no title
  bar, no close/minimise buttons and no border for macOS to draw.
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `titlebarAppearsTransparent = true`.
  The content view is also layer-backed and clear, and the icon is drawn with its own alpha.
- **The transparent parts are not clickable.** `hitTest` returns `nil` where the icon's alpha is zero, so a
  click on "empty window" reaches the desktop underneath — otherwise a 96 pt invisible square would sit on
  the desktop swallowing clicks, which is exactly the widget feel to avoid.
- No background material, no hairline, no rounded rect behind the icon.
- The **balloon is a separate window**, so the pet window itself is never large, never opaque, and never
  in the way: it stays icon-sized and the balloon floats above it while it is open.
- The shadow you see is the icon asset's own alpha, not a window shadow.

A guard test pins those four window properties, because a borderless-but-opaque panel looks correct in
code review and wrong on the desktop.

## Shape of the implementation

### New files (macOS target)

| File | Responsibility |
|---|---|
| `Apps/HermesMac/Pets/DesktopPetController.swift` | Owns one `DesktopPetPanel` per enabled bot. Reads and writes the enabled set, restores positions, reacts to launch, quit, screen changes and bot deletions. |
| `Apps/HermesMac/Pets/DesktopPetPanel.swift` | The window itself: `NSPanel`, borderless, `.nonactivatingPanel`, level `.floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, transparent background, no shadow (the content draws its own). Holds no logic beyond window behaviour and dragging. |
| `Apps/HermesMac/Pets/PetView.swift` | The SwiftUI content: the icon, the idle animation, the hit area, the drag gesture, the right-click menu. |
| `Apps/HermesMac/Pets/PetBalloonView.swift` | The balloon: text field → thinking → answer, plus Copy and dismiss. |
| `Apps/HermesMac/Pets/PetSettings.swift` | The per-bot switch and the saved positions, in `UserDefaults`. One key per bot: `pets.enabled.<bot>`, `pets.position.<bot>` = `"x,y,screenID"`. |

### Changed files

| File | Change |
|---|---|
| `Apps/HermesMac/Views/MacBotSettingsSheet.swift` | A **Desktop pet** section: a `Toggle` ("Show <name> on the desktop") and a "Bring it here" button that centres the pet on the current screen. The toggle reads and writes `PetSettings`. |
| `Sources/HermesKit/GatewayClient.swift` + `GatewayClientActor.swift` | One method: `askBot(profile:question:from:timeout:) async throws -> BotAnswer` hitting `POST /v1/bots/{profile}/ask`, with the `from` field set to `desktop-pet` so the host's own transcript shows where the question came from. |
| `Apps/HermesMac/HermesMacApp.swift` (or `WorkspaceRoot`) | Instantiate `DesktopPetController` once, restore enabled pets at launch, shut them down on quit. |
| `Tests/` | Guards: the toggle writes the same key the controller reads; `askBot` posts the documented route and body; a closed pet writes `false`; positions are clamped to a visible screen. |

### The interaction in sequence

```
click pet ──► balloon (field focused, panel becomes key)
   Return ──► balloon shows thinking ──► GatewayClient.askBot(profile, question, from: "desktop-pet", timeout: 120)
                     │
                     ├─ reply arrives ──► balloon shows the text (+ Copy), pet does a small "done" hop
                     ├─ timeout ───────► "Sent — it hasn't answered yet." with a Retry button
                     └─ error ─────────► the host's own message, unchanged, plus Retry
right-click ──► menu: Close pet ──► setting off, window closes, position forgotten
```

### Decisions worth stating

- **Local, not synced.** Which pets are on *this* Mac is a property of this Mac (its screens, its desk).
  Storing it in `UserDefaults` keeps it out of the host's profile data and avoids a new host route. If it
  should follow him to another Mac later, it becomes a host flag then — the toggle is the only thing that
  would change.
- **`ask`, not the conversation.** A pet asked something does not disturb the conversation open in the
  window; it is a separate turn addressed to the bot. It costs one turn per question, which is the same
  price as typing into the app.
- **A window per pet, not one canvas.** Separate windows get separate Spaces behaviour, separate
  dragging and separate z-order for free, and a crashed panel cannot take the others down.
- **No new animation assets.** The movement is transform-only (offset, rotation, scale) on the existing
  icon, so a bot with a custom picture needs nothing drawn.
- **Reduce Motion respected.** With the accessibility setting on, the pet still bobs slightly or not at
  all, and never hops.

## Edge cases the implementation must handle

| Case | Behaviour |
|---|---|
| Host unreachable / app unpaired | The pet still draws; a question gets "Can't reach the host right now." Never a spinner that never ends. |
| Bot deleted or disabled | Its pet closes at the next refresh and its setting is dropped. |
| Display unplugged, resolution change | Position clamped into the visible frame of the nearest screen on the next launch and on screen-change notifications. |
| Sleep / wake, Space switch, Mission Control | `.canJoinAllSpaces`, `.fullScreenAuxiliary`; no re-layout, no jump. |
| Many pets | Animations pause for occluded windows (`occlusionState`), and each pet's timer is independent so one stuck pet cannot freeze the rest. |
| Long answer | Balloon caps at ~320 × 240 with a scroll view and Copy; the pet never grows. |
| Question while one is in flight | The field is disabled and the balloon shows "still thinking" — one question at a time per pet. |
| Quit the app | Pets disappear with it; enabled set persists, so they come back at launch. |
| Several Macs | Each Mac has its own pets; nothing is shared. |

## What it does not do (yet)

- No pet-to-pet interaction, no pathfinding across the desktop, no sounds.
- No pet on iOS (a phone has no desktop; the icon in the bot list already covers that surface).
- No pet-specific model or prompt: the pet asks the bot the same way you would.
- No dragging between Spaces, and no snapping to window edges.

## Effort

| Piece | Estimate |
|---|---|
| Panel + drag + persistence + settings toggle | 0.5 day |
| Icon, idle animation set, Reduce Motion | 0.5 day |
| Balloon: field, thinking, answer, Copy, error/timeout | 1 day |
| `askBot` client method + tests, guards, docs page | 0.5 day |
| Polish pass: multi-screen, occlusion, several pets | 0.5 day |

Roughly **three days**, shippable in two increments: (1) pet appears, drags, right-click closes, settings
toggle works; (2) the balloon and the ask/answer flow. The first increment is worth testing on its own
because it is where the window-behaviour risk lives.

## Risks, honestly

- **Focus stealing** is the main one: a `.nonactivatingPanel` that also accepts typing needs care — the
  pet must not steal the keyboard from the editor you are writing in when it appears. The field is only
  made key on an explicit click.
- **Over-full-screen apps**: `fullScreenAuxiliary` is best-effort; macOS may hide the pet over a
  full-screen Space, and that is acceptable.
- **The pet is a second door into the same bot.** A question from the pet and a message typed in the app
  can interleave in the same session. `ask` uses the host's queueing, so the worst case is the bot
  answering both in order — but it is worth watching in the first build.
