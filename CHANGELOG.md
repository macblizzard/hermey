# Changelog

All notable changes to Hermey are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions are the app's build versions.

## [Unreleased]

### Added
- **What a bot *is*, in one place: its portrait, its soul, and its memory.** The bot's own page has
  two new rows — **Soul** (its `SOUL.md`, editable) and **Memory** — and Bot Settings owns the three
  identity verbs together: **Bot icon**, **Soul** and **Memory**, beside the description. The icon
  and the soul used to be reachable only by long-pressing the bot's row, which is a gesture nobody
  discovers; the long press is down to what acts on the *row* (settings, pin, hide).
  - **Memory is what it carries into every turn**, and no screen in either app showed it before: two
    documents, `MEMORY.md` (its own notes) and `USER.md` (who you are and what you prefer), each
    with its character count, since that text is replayed into every turn. Read-only — the agent
    maintains those files with its own memory tool, and a text view in a viewer is the wrong place
    to break its rules. A bot that has remembered nothing says so; one whose file could not be read
    says that instead, because the two are different facts.
  - The Mac reads the same two documents from bot settings, from the same shared sheet.
- **A Library file can leave the app.** Long-press a document (or swipe it) on the phone and the
  system share sheet takes the file itself — AirDrop, Messages, Files — with the open document
  offering the same verb in its toolbar. On the Mac the document view writes a copy wherever you
  pick, which also works for a kind of file the viewer will not preview.
  - It shares the *bytes*, not a link: every bridge URL sits behind a single-use device ticket, so a
    URL handed to another app would be dead before it was opened. The staged copy is deleted as soon
    as the share sheet closes, and the file name is reduced to one path component first.
- **Routines: what a bot runs on its own, with a switch beside each one.** The bot page grew a
  Routines row (the Mac's bot panel has the same row) that lists this bot's scheduled jobs — the
  name, the schedule in the host's own words, when it next runs, and how the last run went, including
  the error text when one failed. Each row carries a switch that really pauses or resumes that job on
  the host, so it survives a relaunch and applies to every device. A one-shot that has already run
  says **FINISHED** instead of offering a switch, and a failed run says why rather than only that it
  failed. The list is read from the scheduler every time it opens: a cached copy could draw a routine
  as running that was paused on the desktop last week.
  - No prompt text crosses the wire: a routine's prompt is the bot's own instructions, often long and
    private, and a list of *when this bot runs* does not need it back.
- **Three rows on the bot page say what they open.** *Workspace* is now **Library** (it opens this
  bot's files; "workspace" is the developer's word for the folder the agent works in), *MCP servers*
  is **MCP**, and *Search* is **Search conversations**, which says the scope out loud. The Mac panel
  uses the same three words, and both screens behind those rows carry the new titles too.

- **A banner and a badge when a bot replies in a chat you are not reading.** The bot list already
  had its own counts; nothing reached the operating system. Now a reply on a bot that is not on
  screen raises a notification and puts a number on the Dock tile (macOS) or the app icon (iOS).
  One switch turns it off, and any bot can be quieted individually — a quieted bot still counts on
  its row, it just never buzzes. A chat that is on screen never notifies: its transcript has
  already said it.
  - **macOS is the complete version.** The app keeps running while you are in another app, so the
    banner arrives as soon as the bot list's sweep sees the reply, and tapping it opens that bot.
  - **iOS is honest about its ceiling.** While the app is running, banners are immediate. Once iOS
    suspends it the socket is gone, so the phone learns about a reply through a background refresh,
    which iOS schedules — typically tens of minutes, not seconds. Instant delivery there needs an
    APNs entitlement a sideloaded personal-team build cannot carry.

### Fixed
- **The unread count no longer lags the banner.** The number travels in the same answer as the
  preview, but it is a *snapshot*: the bot list opens four or five reads inside three seconds, and a
  whole-map replace let a slower or failed answer put the count back to zero until the next 25 s
  sweep. A reply now puts a floor of one under that bot's count the instant the banner goes up (the
  next read replaces it with the host's exact number), only the newest read may set counts, a failed
  read leaves the last answer standing instead of emptying every badge, and a sweep already open is
  joined rather than repeated.
- **The unread count is back on every bot's face, and the row's beacon with it.** The roster restyle
  of 2026-11-13 replaced both indicators with one static dot on the theory that the app-icon badge
  was enough — it is not: that number needs the app closed to be read. Both shells now show what was
  asked for: a numeric capsule on the avatar (how much is waiting, `99+` at the ceiling, nothing at
  zero) and the breathing beacon at the row's trailing edge (something is).
- **A reply in another chat raises a banner again while the app is open.** The phone was dropping
  every foreground notice, so a phone sitting in one bot's chat learned about a reply from another
  bot nowhere. The decision already belongs to `ReplyNotificationPolicy`, which refuses the bot whose
  transcript is on screen and any bot the user quieted — the shell now only delivers.
- **A read mark is written from the host's clock, not the device's.** Every unread comparison is
  against host timestamps, so a phone whose clock ran even a minute fast wrote a mark in the host's
  future and then never lit that bot again. Both doors that mark a bot read now use the host's newest
  message for it.
- **The bot list's top edge, and the conversation's search field.** The "CHATS" label is gone — it
  said what the rows already were and cost a line between the bar's two buttons and the first bot,
  which now sits closer. The list fades out under the bar instead of meeting it with a hard seam:
  a row scrolling up dissolves into the canvas before it reaches the buttons. And "Search
  conversations" no longer opens a field drawn bare onto the transcript — the search bar is a glass
  pill, the same material as the bot pill above it.
- **Compacting no longer fails when the phone goes to sleep.** A compaction is 2–3 minutes of *host*
  work (measured 74 s, 123 s, 163 s here) and iOS tears the socket down the moment the app leaves the
  foreground — the bridge logs `client_closed` 1001 about 200 ms after the request, and the app then
  told you "could not compact — The operation couldn't be completed. Software caused connection
  abort" while the host was still working. A lost answer is no longer treated as a refusal: the state
  stays "compacting… the host keeps working while the app is away", nothing can start a second one,
  and the next transcript the host hands back settles it — "conversation compacted" if it changed, and
  an honest "compacting did not report back" once five minutes have passed with no reconnect. A real
  refusal still says so, and an errno never reaches the screen as the reason.

### Fixed
- **Minimising the app no longer blanks the chat, and coming back lands at the newest message.** A
  foreground sends `gateway.ready` again, and the answer used to be a fresh `select()` — which empties
  the transcript before it asks the host anything and then replaces every row after a new layout pass.
  On a long thread that was a blank pane for the whole host read (measured ~4 s at 2,500 rows) and a
  scroll view that kept its old offset, so the reader came back somewhere in the middle. A reconnect
  now re-reads **in place** (`refreshTranscript`: no clearing, no reset turn state, rows replaced when
  the host answers, a failed read leaves the screen alone) and bumps `transcriptReloads`, which the
  chat turns into "land at the end".

### Changed
- **The phone's conversation menu is a page you swipe in from the right edge.** The bar's ⋯ is gone
  from a chat by instruction: a swipe in from the trailing edge opens the same verbs — Computer,
  Workspace, Skills, MCP servers, Search, Settings, Compact (with its running state), Mark all as
  read, Speak replies, Reset chat — as a full-height panel with a dimmed conversation beside it.
  Swipe right or tap outside to close. The gesture is measured (28 pt in from the edge, leftwards,
  more horizontal than vertical) so a diagonal scroll never opens it, and the transcript's own drag
  handler skips it, so an edge swipe is not read as the reader parking the scroll. The **bot list
  keeps its ⋯**, which is what he asked for.

### Fixed
- **Compacting now says it is running, on both apps.** The verb always worked: the bridge log shows
  `session.compress` answering `ok` after **74 s** and **163 s** on two real runs. Neither app drew
  anything for those minutes — the menu closed on tap, `isCompressing` was set but rendered nowhere,
  and the Mac's outcome note sat behind a 460 pt width breakpoint — so a compaction that succeeded
  looked exactly like a dead button. Now a `compacting…` chip with a spinner appears in the Mac header
  (and the phone's strip, which is always on screen), the compact button becomes an hourglass and
  refuses a second tap, both menus keep the verb visible as *Compacting…*, and the outcome chip is
  drawn at every window width. The phone's item was also disabled by a session id the view had not
  learned yet, though `compressNow` opens the conversation itself.

### Changed
- **Loading a chat no longer queues behind duplicate requests.** One app launch was measured posting
  `profiles.list` twice, `session.list` five times and `model.options` three times inside three
  seconds — the last of those answering only after 3.7 s — and a reconnect repeated the burst. The
  gateway answers them one at a time, so the transcript waited on work nobody asked for. `GatewayClient`
  now collapses identical in-flight reads into a single round trip (`performRead`, keyed by method and
  params), remembers the model catalogue for two minutes because it costs the host seconds and changes
  only when the model does, and forgets everything it remembered when a write invalidates it
  (`profiles.configure`, `model.save_key`, `session.compress`). A refusal is never remembered.

### Added
- **The Mac has the three per-bot panels the phone got.** ⋯ → **Workspace…** opens a sheet with the
  documents on the left and the document on the right — same viewer rules, same read-only rule: text in
  a monospaced reader, PDFs in `PDFView`, images at full size, and "no preview for this kind of file"
  instead of a blank pane. **Skills…** and **MCP servers…** are the same two lists with switches, read
  from the same host calls as the phone. All three share the window's single modal route, so opening one
  closes the others rather than queueing a sheet behind a sheet.

### Added
- **Skills and MCP servers, per bot, from the ⋯ menu.** Two new panels list what a bot may reach for —
  its skills under *Skills*, its MCP servers under *MCP servers* — each row a switch. Flipping one
  rewrites that bot's own config on the host, so it survives a relaunch and applies only to that bot:
  a disabled skill leaves the bot's index entirely (it cannot be called by name either), and a disabled
  MCP server stops being started for it. `profiles.configure` **replaces** both lists wholesale, so the
  app sends the complete set computed from `profiles.describe` — sending a one-item delta would silently
  switch off everything else the bot had.

### Added
- **A workspace, with a viewer.** The ⋯ menu in a conversation now opens the bot's workspace: the
  documents it prepared, and the files you sent it, in one list with sizes and ages. Tap one and it
  opens — text as text, PDFs in a real PDF view, images at full bleed. Anything that cannot be laid out
  from its bytes (`.docx`, `.xlsx`) says so plainly instead of showing a blank page, and the list is
  strictly read-only: a stray gesture cannot tidy away a document a bot is still working on.
  The bridge grew `GET /v1/workspace/<profile>` and `GET /v1/workspace/<profile>/file?path=`; both are
  device-authenticated, refuse symlinks, refuse traversal, and serve byte ranges so a PDF can page.

### Added
- **The Mac app is published as a `.dmg` as well as a `.zip`.** The image opens as a window with
  `Hermey` beside an `Applications` shortcut, so installing is one drag instead of unzip-then-move. The
  zip stays for scripts and build servers, and both are `hdiutil verify`-checked before upload. No
  notarization is involved: a disk image is not what Gatekeeper objects to — the unsigned app is, and
  it behaves the same inside an image as inside an archive.

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

### Fixed
- **Compact does something now, on both platforms.** The button asked the host to compact a session by
  its *stored* id; the host addresses sessions by the *runtime* id, which this process only learns from a
  resume. A conversation restored from the last launch therefore answered `4001 session not found` — and
  that error went to a field no view renders, so the button looked dead. It now opens the session first
  and retries once, and a refusal (including "session busy — stop the reply first") is written into the
  header notice instead of vanishing.
- **A long chat no longer opens on a blank pane.** Measured on a real 2,503-row conversation: a resume
  costs the host ~4 s. The rows this process already has are now painted immediately and replaced by the
  host's answer when it lands, so returning to a chat is a refresh rather than a wait. Memory only — the
  host stays the authority.

### Fixed
- **CI stopped filling the account's Actions storage.** The plan includes 500 MB shared by caches and
  artifacts; the repo was at 100% with 1.4 GB of DerivedData caches and 214 build artifacts kept for 90
  days. Caching is gone from the workflow (`.build` and DerivedData are hundreds of megabytes a key),
  uploaded artifacts now expire in two days, and the repo's artifact/log retention is set to 3 days. A
  release still publishes from the artifact within minutes of the run finishing, so nothing about
  shipping changes — builds are simply slower.

### Fixed
- **The bridge is a managed service again, deployed from this repo.** The unit pointed at an older
  tree (`/opt/hermes-apps/Bridge`, system `python3`) while the running process came from
  `/opt/hermey/venv`, so a restart would have silently run different code — and its sandbox
  (`ReadWritePaths=/var/lib/hermes-bridge`) did not match the database the deployment actually uses.
  The unit now runs the venv, with `/var/lib/hermey` and the profile tree writable, `Restart=always`,
  and its state directory named in `bridge.env`, so paired devices survive a restart. Deploys are one
  command: `Tools/release/deploy_bridge.sh` installs `./Bridge` into that venv and restarts the unit.

### Fixed
- **The Skills panel now lists the bot's real skill index, not its own folder.** `profiles.describe`
  reports only the skills installed inside a bot's profile directory — one or two on this host — while
  the bot actually draws on the shared library (236 skills across 25 categories here). The panel merges
  the host's filtered hub list with the profile's own entries, so a skill this host cannot run shows as
  off rather than missing.
- **The bridge lets a device flip those two lists, and nothing else.** `disabled_skills` /
  `enabled_mcp_servers` are now accepted by `profiles.configure` from a paired device — names only,
  capped at 500, each matching `[A-Za-z0-9][A-Za-z0-9._-]*`, with `enabled_toolsets` and `ui_meta` still
  host-only. `skills.manage` is allowed for `action: list` alone; an `install` from a phone is refused
  before it reaches the gateway.

### Fixed
- **The chat no longer flickers while a reply streams, and scrolling up while a bot is working stays
  put.** Both had one cause: every streaming change scrolled the transcript, so a reply arriving at
  tens of tokens a second re-laid out the view tens of times a second, and the drag was overridden by
  the next token. Scrolling is now coalesced to one in flight at a time, and "at the bottom" comes
  from a measured distance rather than from a sentinel row appearing — with the reader's own intent
  (`followsStream`, set false the moment a finger drags) deciding whether a token may pull the view
  down at all.

### Fixed
- **The macOS download no longer routes through GitHub's release CDN.** That CDN stalls mid-transfer
  on some networks — the transfer starts and stops making progress while the file is otherwise fine.
  CI now publishes the image to a small Pages repo as well, and the site links *that*: a plain `200`
  with a `Content-Length`, `accept-ranges`, and no redirect in front of it.
  <https://macblizzard.github.io/hermey-downloads/Hermey-macOS-unsigned.dmg> The release asset is
  still attached for anyone who prefers it.

### Fixed
- **The Mac app launches on Apple silicon again.** CI built with `CODE_SIGNING_ALLOWED=NO`, so the
  universal binary carried no code signature at all — and an arm64 binary with no signature is not
  merely untrusted, the kernel refuses to execute it and macOS reports the app as **damaged**, which
  `xattr` cannot fix. The build now ad-hoc signs (`codesign --force --sign -`) before packaging, then
  mounts the finished image and verifies the signature and the `/Applications` shortcut from *inside*
  the artifact that gets uploaded. Ad-hoc needs no certificate and changes nothing about Gatekeeper's
  verdict: the first-launch quarantine step, and the `xattr` line, stay exactly as documented.

### Fixed
- **The chat scrolls again on iOS.** A `DragGesture(minimumDistance: 0)` on every message row took each
  touch from the scroll view, so nothing scrolled. The press location it was added for is not worth a
  dead chat: the card's arrow now points at the middle of the message's **visible** slice, measured from
  the row's frame against the screen, and the long press is the only gesture on a row again.

### Fixed
- **The long-press card opens where your finger is.** It was anchored to the message's whole
  rectangle: for a long message that rectangle is taller than the screen, so "above the row" meant the
  top of the page. The card now anchors to the press point inside the row, and chooses its side from
  the pressed line rather than from the row's middle.

### Fixed
- **The long-press card opens above a message at the bottom of the screen.** It was asked for with a
  fixed `arrowEdge: .top` — always below the row — and at the bottom of the screen there is no room
  below, so iOS placed what fitted and clipped the rest. The reactions are the first thing in the card,
  so they were exactly what disappeared, leaving slivers of colour along the top edge. The row now
  reports its own frame and the card opens on whichever side has room.

### Fixed
- **Switching bots no longer flashes an empty chat.** Every switch cleared the pane and then waited
  for `resumeSession` — one round trip, 1–2 s, every time, including going back to a conversation that
  was on screen moments earlier. Nothing was cached. Each bot's transcript is now kept in memory (the
  eight most recent, oldest evicted), the pane paints that snapshot *before* anything is asked of the
  host, and the resume still runs and silently replaces it. A bot with nothing cached says "Opening
  cody…" instead of the "Start the conversation with cody" placeholder, which claimed the history was
  gone. "Reset conversation" evicts the snapshot, so a reset stays reset.

### Fixed
- **The emoji picker hangs off the smiley, and 👍 is not ringed.** The popover was attached to the
  message row, so it anchored to the row's whole width — opening below and to the right of the button,
  465 pt wide, arrow pointing at nothing. It is attached to the smiley now
  (`attachmentAnchor: .rect(.bounds)`, `arrowEdge: .bottom`) and sized to its six emoji. The square
  outline around the first emoji was macOS handing focus to the popover's first control: focus is off
  and the focus effect disabled, and each emoji has a name for its tooltip.

### Added
- **Tooltips on the desktop's buttons.** Glyph buttons had no answer on hover while every one of them
  already carried a `label` for VoiceOver and the message row already passed a `help:` that was never
  used. `OpenBotIconButton` now shows its label as the tooltip (macOS only — iOS has no hover), the
  message action glyphs show theirs, and the composer's dismiss/cancel-reply/remove-attachment ✕, the
  jump-to-latest button and read-aloud are all named. Menu items and alert buttons are left alone:
  macOS does not draw tooltips inside menus.

### Fixed
- **Double-clicking the top strip zooms the window everywhere, not just over the chat.** The stand-in
  title bar started 96 pt in — past the traffic lights — which left the band above the sidebar's
  search field dead: the same gesture that zoomed the window over the conversation did nothing there.
  It now covers the full width (the traffic lights are hit-tested by the window's own frame first),
  and a double-click follows the system preference (Desktop & Dock → "Double-click a window's title
  bar to": zoom, minimise, or nothing) instead of always zooming.
- **The shared computer takes a physical keyboard.** Keys were only read from the viewer's hidden text
  area, and on a Mac nothing ever focused it — no soft keyboard, the ⌨ button hidden for coarse
  pointers, the pane opening with the caret nowhere — so typing went into the void while the remote
  desktop sat there looking ready. The page now reads keys at the document (one capture-phase
  listener, covering the text area, the canvas and the body), focuses the text area on a pointer press
  on desktops so paste and dictation still have a target, and leaves ⌘ chords to the Mac.
- **Reactions are on the message, not behind a menu.** The desktop's action row (speak, copy, reply)
  gained a smiley that opens the six basic reactions; the phone's long press now raises one compact
  card — the six emoji on top, four 32 pt rows under them — instead of a system menu taller than the
  message with the emoji hidden behind "Add reaction".

### Changed
- **One Mac artifact: the `.dmg`.** The zip was a wrapper around the same `Hermey.app`, so CI now
  builds only the disk image and the release publishes only it. `publish_altstore.py` and the shell
  wrappers dropped `--mac-zip` in favour of `--mac-dmg`.
- **The unsigned first launch is documented where people look.** `docs/APPS.md` and the landing page
  both give the one-liner that authorises the app —
  `xattr -dr com.apple.quarantine /Applications/Hermey.app` — next to the right-click → Open route,
  because "cannot be opened because the developer cannot be verified" is the first thing a Mac user
  meets and the fix is not obvious.

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
