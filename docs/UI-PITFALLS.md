# SwiftUI traps this app has already paid for

Each of these shipped a bug that looked like "the feature does not work" while the code read fine.
They are listed here so the next change does not rediscover them.

## Presentation

- **A method declared only in an extension is chosen statically.** `func rooms()` on
  `extension BotSessionPointerStore` never ran when called through `any BotSessionPointerStore`;
  every call took the *default* and answered "this host's bridge does not support". Anything a
  protocol is meant to dispatch must be a **requirement on the protocol**, with the conformance
  supplying the body.
- **One view, many `.sheet` modifiers, is a lottery.** After six or seven, a later sheet silently
  never appears (rename: the request never reached the host). If a feature can live
  inline — a field that drops under a header — prefer that. Otherwise consolidate presentations
  behind one `enum` + `sheet(item:)`.
- **A `List` inside an `.alert`-free Mac sheet has no intrinsic height**: the sheet collapsed to its
  title bar and "Manage bots" looked empty. Use `.sheetSizing()` (`Components.swift`).
- **An `.alert` with a `TextField`** did not open reliably on macOS. A small sheet, or an inline
  field, works.

## Type checking

- The compiler gives up ("unable to type-check this expression in reasonable time") on long
  modifier chains over `List` rows. Symptom: CI fails on a file that parses cleanly. Fix by
  extracting each section/row into a named `private var`/`func`, and pulling dialog arguments
  (title, `Binding`) out into properties.
- Initialiser argument order is declaration order: adding a property above existing ones changes
  every call site ("argument 'x' must precede argument 'y'").

## Platform

- `navigationBarTitleDisplayMode` does not exist on macOS — use `.inlineSheetTitle()`.
- `NSPasteboard` / `UIPasteboard` need `#if os(macOS) import AppKit #else import UIKit #endif`.
- `.fileImporter`, `.photosPicker` and `confirmationDialog` must be attached to a view that is
  actually in the hierarchy: a modifier added to a computed subview that was later refactored away
  is silently dropped (the paperclip bug — it set state nothing listened to).

## Alignment and chrome

- **Two different gutters in one conversation read as a tilted screen.** A room's transcript was
  padded 12 and its composer 0 (the chat's were 16 and 12), so every bubble floated over a field
  that touched both edges. One value, `Geometry.chatGutter`, is now read by the transcript, the
  composer and the strips between them, in **both** conversation kinds, on both platforms. A new
  message surface copies it rather than picking a number.
- **Do not put a custom view in a bar if the system one will do.** A `ToolbarItem` whose label is
  not a plain glyph is wrapped by iOS 26 in its own glass capsule: the hand-drawn back button became
  a 44 pt disc, the ⋯ button was a rounded square inside a circle, and the title stopped centring
  between them. A bar button is a glyph; chrome belongs to the bar.
- **`.navigationBarBackButtonHidden(true)` also kills the edge-swipe pop, and a delegate does not
  bring it back.** It was handed `interactivePopGestureRecognizer`'s delegate in `onAppear`; the
  swipe still did nothing on device, because SwiftUI re-establishes the bar (and the recogniser's
  state) on its own layout passes. Keep the system back button: the swipe, the centred title and the
  bar's padding are one package, and a badge is not worth trading them for. The unread count belongs
  in the header strip (it takes the entries label's slot, so the row cannot overflow).

## State and identity

- A selection guard that returns early before dismissing a *different* presentation makes a list
  feel dead: `selectBot` bailed on "same bot twice" while a room was on screen.
- A room and a bot share one conversation pane; `AppModel.activeRoom` is the tie-breaker, and the
  sidebar must highlight exactly one of them.
- Re-read host state in the model, not in a sheet's `@State`: a room list that lived in a sheet's
  state vanished when the sheet closed.

## Composer

- On iOS `Composer.defaultHint` is `nil`; passing an explicit hint string puts "⏎ send" over a touch
  keyboard. Pass `composerHint`, which is platform-aware.
- Never restore the draft after a failed send: a slow host accepts the message and misses the
  reply, and the restored text makes the composer look like it ignored the tap. Re-read the log to
  see whether it landed.
## Protocol extension defaults

- A protocol extension default that returns `{}` (or `[]`) is a *silent success*, and a concrete
  type that forgets one inherits it. `BotSessionPointerStore` declares `renameRoom` and
  `disbandRoom` as `async throws {}` "for stores with no admin routes"; `BridgeBotSessionPointer`
  implemented rooms/create/log/send and never overrode those two, so renaming a group chat sent
  nothing, threw nothing, and looked broken on the Mac and the phone at once. Every admin verb on a
  concrete store needs a test that asserts *the request* — method, path, ticket, body — because a
  behaviour test on `AppModel` still passes when the store no-ops.
- The bridge audit log is the fastest discriminator: `rooms.list` from the device with no
  `rooms/<id>/rename` at the same timestamp means the app never sent anything, so stop looking at
  the host.

## Toolbar

- `.topBarTrailing` / `.topBarLeading` do not exist on macOS: a shared `OpenBotUI` view that sets
  them fails the Swift package build (and so `main`), even though the iOS app compiles fine. Use
  `.primaryAction` in shared code, or wrap the item in `#if os(iOS)`.
- A bar button is a glyph, not a disc: `Tokens.control` is the fill for a control sitting on a
  card, so a circle of it on the canvas reads as a pale blob with a dim glyph inside.
