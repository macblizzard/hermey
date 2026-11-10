# Changelog

All notable changes to Hermey are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions are the app's build versions.

## [Unreleased]

### Fixed
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
