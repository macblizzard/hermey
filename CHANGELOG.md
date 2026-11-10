# Changelog

All notable changes to Hermey are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions are the app's build versions.

## [Unreleased]

### Added
- **The phone can copy a code block — and both apps say when they did.** The desktop's code cards had a
  copy button that copied in silence, so the same press happened twice; the phone's had no button at
  all, leaving a long press and two drag handles as the only way to take a command off the screen. One
  shared `CodeCopyButton` now sits in both headers — language on the left, verb on the right — and the
  glyph turns into a tick where it stands for a second and a half, with a haptic, before going back.
- **Mark all as read.** The ⋯ menu on both apps — the bot list's and the conversation's — now clears
  every badge at once. Opening a chat has always read it; this is the same act for the list, so nine
  badged bots and a couple of badged rooms no longer have to be opened one by one to clear dots the
  person never meant to read. The marks are written the same way opening a chat writes them, so a dot
  cannot return on the next refresh, and each room is read up to its own `latest_seq` rather than a
  number this side invents. The item greys out when nothing is waiting.
- **The app says what is on screen at launch.** A blank rounded panel appeared over the sidebar on a
  first launch and closed with Esc, and no surface in the app presents itself: every overlay is behind
  a flag the user raises. Rather than guess, the workspace now writes two lines to the log a second
  after launch — every window with its class, title, identifier, visibility, level, size and origin,
  and the state of every flag that can raise a surface — readable in Settings → View log. A palette
  with no verbs is also refused now instead of drawing an empty box.
- **A picture you sent has no Save.** The viewer takes `canExport`: off for your own attachment (it is
  already on your disk — saving it back is busywork), on for a picture the host produced or one that
  arrived from elsewhere. Copy stays either way.
- **Pictures open.** Clicking an attached image on the Mac, or tapping one on the phone, now opens a
  viewer instead of doing nothing: the picture at its own size with zoom (+/−, `Fit`, pinch), the
  pixel dimensions and file size, Copy, and — for pictures you did not send — Save (Mac: a save panel;
  phone: the share sheet). The
  bytes are shown exactly as they arrived — nothing is re-encoded. `ImageViewer` lives in
  `OpenBotUI`, so the artifacts a host generates will open in the same one once they are rendered in
  a transcript (they are not drawn anywhere yet — the host sends no attachment metadata for its own
  replies, so that needs a host-side fetch, not a view).
- **The footer fits a phone.** The bar was four text controls plus a primary button, so on a narrow
  screen `Done` was squeezed to `D…`; the secondary verbs are glyphs with 30 pt targets now, the
  report ("Copied", "Saved") is a word over the picture instead of a fifth control, and `Done` has
  `fixedSize` and the highest layout priority.
- **"N unread" in a bot chat's header strip:** the replies waiting in the *other* chats (other bots
  plus any group chat with new lines), refreshed while the chat is open. It sits beside the model
  chip and takes the entries count's place while it is showing — one count per row — and tapping it
  goes back to the list. It is **not** on the back button: a custom bar button is drawn by iOS inside
  its own glass capsule, which pushed the title off centre, and hiding the system back button
  disabled the edge-swipe, so that version could not ship.
- **Unread badges on group chats.** A room row now carries the number of bot messages that landed
  since this device last read it, drawn on the room's faces exactly where a bot's count sits on its
  portrait. `groups.list` reports only each room's newest `seq`, so the count comes from the room's
  own log — fetched only for rooms that moved, and seeded rather than badged on first sight.
- **Settings → Diagnostics → View log** (About → *View log…* on the Mac): a timestamped, on-device
  record of what the app did — connects, socket drops and reconnects, failed session opens, refused
  sends, compaction failures, room reads — with Copy, Share and Clear. The log survives a relaunch,
  is capped at 400 lines, and mirrors to the system log for `log stream` on the Mac.

### Changed
- **The three-dot menus open smaller.** The bar button is unchanged (a bare glyph, as before) — the
  popup was what was wrong: every row's label is shorter ("Search", "Compact", "Reset chat",
  "New group chat", "Hidden bots"), so the panel is narrower without losing a single verb.
- **A conversation has one gutter.** `Geometry.chatGutter` (16 pt on the phone, the Mac's 24 pt
  reading inset) is used by the transcript *and* the composer, in both a bot chat and a group chat.
  A room's composer used to sit flush against the screen edges while its bubbles stopped 12 pt in,
  and a bot's composer was 4 pt wider than its own text; both now line up.

### Changed
- **The Mac's ⋯ menu no longer offers "Bot computer…"**: the header's own display button is the door,
  and a verb that repeats the button beside it made the menu read as a second toolbar.
- **Text is no longer washed out on the Mac.** `TypeScale.font` accepted a `Font.Weight` and dropped
  it: `.custom("Inter", size:)` cannot take one, so all 64 call sites that asked for `.semibold` or
  `.medium` drew the regular face — and Inter is not bundled, so the request fell back to the regular
  system face as well. The helper now asks for Inter only when the family is actually installed and
  otherwise draws the system face *at the weight requested*, at sizes rounded to a half point (a 0.85
  step used to draw 11.9 pt). The Mac composer's text view follows the same rule instead of asking
  `NSFont(name:)` for a family name, which always answered nil.
- **Opening the shared computer no longer clips the window.** The computer pane was a fixed 520 pt
  added to a window whose minimum width was computed for two panes, so the `HStack` overflowed and the
  shell was cut on *both* sides — the bot panel's labels on the left, the pane's buttons on the right.
  The pane now has a floor (320), an ideal (520) and a ceiling (760), the conversation hands back some
  width while it shares the window, the window's minimum follows the arrangement
  (`WindowLayout.minimumWidth`), and a narrow window is grown to fit rather than clipped.
- **The Mac stays paired across launches.** The pairing was written only to a data-protection
  Keychain item, which needs an application identifier — and the app ships unsigned, so
  `SecItemAdd` answered `errSecMissingEntitlement` (-34018), nothing was stored, and every relaunch
  asked for a fresh code from `hermey pair`. `PairingStore` now writes all three tiers it can
  (data-protection Keychain, login Keychain, and a `0600` file excluded from backups under
  Application Support) and reads the Keychain first, the file second; Settings says which one holds
  it, and the pairing log records the `OSStatus` when a tier refuses.
- **A pairing code is now accepted by the host instead of answered 422.** The Mac app sent the claim
  body as `publicKey`/`deviceName`; the host's model is `public_key`/`device_name`, so the request
  failed validation ("field required") and the sheet could only report the status code. The body and
  its field names moved to `PairClaimBody` in the kit (the phone had always spelled them itself), and
  refusals now carry the host's own reason — including FastAPI's array-shaped `detail`.
- **A code from `hermey pair` pairs on a Mac that has never paired.** A fresh Mac has no remembered
  host, so a bare eight-digit code parsed to nothing and the sheet called it "not a pairing code" —
  the digits were refused on the device and never reached the host; only the full `hermes://` link
  worked. `PairingLink.classify` now separates *a code with no address* from *not a code*, and the
  sheet answers the first by keeping the digits, opening Advanced and focusing the address field
  (which it then claims against). An address typed there also outranks one remembered from the last
  pairing, so re-pairing to a different host no longer needs the link.
- **The edge-swipe stopped going back.** Hiding the system back button to draw one that carried the
  unread bubble also switches off `interactivePopGestureRecognizer`, and the delegate it was handed
  back did not survive SwiftUI's layout passes. The bar keeps its system back button, so the swipe,
  the centred title and the bar's own chrome are the ones iOS draws.
- **A reply printed itself twice while it streamed.** The host streams the whole message of the turn
  while each paragraph it seals (at a tool call, again as `message.interim`) becomes a row of its
  own, and the rules only compared against the *last* row — so a turn whose two earlier paragraphs
  were already on screen got them printed again in the bubble underneath (screenshot, 03:16: "Two
  answers change the plan…" and "Chrome 157 is in…" twice). The bubble and the completion gate now
  compare against every row the turn has written and keep only the paragraphs nobody has said.
- **"could not compact: session.compress timed out after 120s".** A compaction is a real model turn
  on the host, budgeted there to 600 s (`compression.context_total_ceiling_seconds`); the app cut it
  off at 120 s, so a large bot (218k tokens) could never compact from the phone. The client ceiling
  is now 660 s, the host's own budget plus a margin.
- **A long bot conversation would not open at all on the phone.** `session.resume` answers with the
  whole transcript in one frame; this bot's chat is 3.4 MB, and iOS refuses to deliver a message
  that size — "could not open the conversation: … Message too long" — so the screen stayed empty
  while the socket reconnected to retry the same oversized frame. The bridge now ships the newest
  page with the resume (200 rows / 512 KB, whichever comes first) and serves older pages from its
  own copy of that resume, which the transcript reaches through a new **Load earlier messages** row
  on the phone and the Mac. Measured through the live bridge: 3,396,481-byte resume became 423,243
  bytes, and paging walked all 1,450 rows back to the start with no gap.
- **Bot computer clicked in the wrong place while zoomed, taps stopped registering, and the last
  reply duplicated itself row-by-row.** noVNC counted the zoom twice in every pointer coordinate
  (patched, with a check under `Tools/verify`); its touch recogniser was being fed a partial event
  stream and wedged, so this page now owns touch input outright; and the same paragraph arriving as
  a sealed commentary, an `message.interim` and a completion is now written once.
- **Right click landed away from the pointer, and pinching stopped working once its menu was open.**
  The click now goes where the pointer stands, not between the fingers; and noVNC's capture proxy
  div — laid over the whole page by its legacy `setCapture()` on a synthetic press — is released
  afterwards instead of swallowing every later touch.
- **The last reply appeared twice while it streamed.** A commentary sealed as `message.interim`
  became both a row and the live bubble; the bubble now prints only what the trailing row has not
  already said, and a completion that repeats that row does not append a second copy.
- **Bot computer: pinching froze the pointer, and there were two keyboard buttons.** The pinch
  swallowed the `touchend` noVNC needed to close the gesture it had opened, leaving a button pressed
  for the rest of the session; it now releases the pointer explicitly and lets the touchend through.
  The header keyboard button is gone — the floating ⌨ in the picture (touch devices only) is the one
  that works, because a tap in the page is the only focus WebKit accepts as a user gesture.
- **Typing, zooming and empty timestamps.** The Bot Computer keyboard did nothing (iOS raises keys
  only for an editable focused by a tap inside the page, so there is now a hidden text area, a real
  ⌨ button, and keys sent through noVNC's `sendKey`); there was no way to zoom (pinch 1×–4× and
  two-finger pan, with one finger still the remote pointer); and hiding tool calls left wordless
  assistant banner rows as blank bubbles with a timestamp — those rows are gone, and times now show
  only on messages with something to read.
- **Bot computer showed `NSURLErrorDomain Code=-999 "cancelled"` on opening.** That is a cancelled
  request, not a fault: the poll loop restarts on every state change and SwiftUI cancels the request
  in flight. Cancellations are now silent, other failures are one sentence instead of an NSError
  dump, and a healthy poll clears a stale strip.
- **Bot computer showed nothing at all.** The view loaded the `wss://` socket as if it were a web
  page, so the bundled viewer never ran — no script, no socket, no picture, and a spinner where the
  desktop should be. It now loads `hermey-novnc://local/botcomputer.html?ws=…` with the socket as a
  query parameter (one builder in HermesKit, tested), which is what the bridge log showed was missing:
  tickets minted, viewer socket never opened.
- **Bot computer: the window, the input and the black pane.** Three defects from the first hands-on
  test. The phone showed it in a sheet, so dragging the desktop dismissed it — it is now a full page
  with its own Close button. "Take over" enabled nothing: the flag was pushed into the page before
  noVNC's module had loaded and was never replayed, so pointer and keyboard stayed off; the page now
  keeps the flag and applies it on connect, and a keyboard button raises the keys on purpose. Taking
  over or handing back left a black pane: the viewer is now re-opened on a fresh ticket after every
  lease change, says "Connecting…" until the socket is up, retries a dropped stream twice, and shows
  the page's own error text instead of a silent black rectangle.
- **"Show tool calls" off now hides the cards.** The switch was wired to the card's *output*, so a
  user who turned tool calls off still saw every command in the chat and read the setting as broken.
  Off removes the tool rows from the transcript (history is untouched — turning it back on shows them
  again) and stops the running turn from drawing live cards either. The label now says what it does.

### Added
- **Bot computer: right click.** A two-finger tap while in control is a right click at the point
  between the fingers (`MouseEvent.buttons: 2` through noVNC's own pointer path), with a one-time
  hint on take-over.
- **Bot computer** in both apps: the host's shared headless desktop, opened from a bot's chat — the
  phone's ⋯ menu, or the Mac's display button / ⋯ menu. The Mac shows it as a **right-hand panel**
  with a full-screen option; the phone opens a full-height sheet. Watching is live; **Take over**
  enables input (the host's lease is the gate), **Hand back** returns the screen to the bots.
- The bridge's `/v1/display` surface: status, thumbnail, start/stop, the takeover lease, and a
  single-use ticket for the RFB socket (the gateway's own ticket never reaches a device).
- noVNC 1.7.0 is bundled in both apps (unmodified, MPL-2.0) and served to the viewer over a private
  URL scheme, so its ES-module imports resolve without a file:// origin problem.

### Notes
- The desktop is **shared by every bot**: the same browser profile and the same logins, one Xvnc.
  While a human holds control, every bot's `computer_use` is refused — that is the design, not a bug.
- iOS keyboard input into a remote desktop is the weakest spot; typing a password or a 2FA code is
  the supported case, not general typing.

## [0.1.14] — 2026-11-09

### Added
- The Mac **Pair a host** sheet takes a code: paste the eight digits from `hermey pair`, or the whole
  `hermes://pair?…` link, and the app claims its own device row (`PairingClaim`, `PairingLink`).
  One field up front; the WebSocket URL / device ID / token fields live behind **Advanced**.

### Fixed
- A code from `hermey pair` could not be used on the Mac at all — the sheet had no claim step, so a
  pasted code went into the URL field and the host answered "bad response from the server".
- `Tools/release/sync_store.py` uploads `icon-512.png` when a release lacks it, retries URL checks
  through the CDN's propagation window instead of calling a good URL broken, and names which field
  drifted rather than reporting matching versions as drift.

## [0.1.13] — 2026-11-09

### Added
- Unread counts: each bot's avatar carries a capsule in its bottom-right corner with the number of
  turns that bot wrote after this device last looked at it (`UnreadBadge`, both apps). The breathing
  beacon stays at the end of the row — one says something is waiting, the other says how much.
- `POST /v1/bots/previews` takes this device's read marks and returns the rows plus counts in the one
  read the list already makes. Only the bot's own turns count, only in the session the app opens, and
  a bot with no mark is never counted.

### Fixed
- The AltStore/SideStore source is regenerated from each release's own `.ipa` by
  `Tools/release/sync_store.py` (release asset and `gh-pages`), so a hand-cut release cannot leave a
  stale source behind. It found the source pointing at an `app-icon-1024.png` that was never uploaded.
- The Pages landing page links to the latest release instead of naming one build.

### Added
- `Tools/release/sync_store.py` (+ the `Store sync` workflow): regenerates the AltStore/SideStore
  source from the newest release's `.ipa`, repairs a stale one on the release asset and on `gh-pages`,
  and fails when either still reports a different build. Verified URLs are part of the check — the
  previous source pointed its header at an `app-icon-1024.png` that was never uploaded.

## [0.1.4] — 2026-11-08

### Added
- `setup/install.sh`: one command installs a Hermey host — service user, venv, loopback bridge,
  `tailscale serve` for TLS, `hermey` CLI (status, pair, logs, doctor, update, uninstall), and an
  idempotent upgrade path. It reuses the Hermes dashboard already running on the host.
- `hermey pair` mints a fresh code, a `hermes://pair` deep link and a scannable QR.

### Fixed
- Group chat messages render as markdown (bold, lists, quotes, code, tables) at full width instead of
  raw source inside a narrow bubble.
- Scrolling a group chat dismisses the keyboard, as a one-to-one conversation does.
- A pairing code names the host the requesting client used instead of a fixed domain.

## 0.1.3 and earlier

Bot list home screen, endless conversations per bot, group chats with rename/delete from the row's
context menu, per-message read-aloud through the host voice, copy, reply and reactions, the composer
clear button, approvals, attachments, and the three-pane macOS shell.
