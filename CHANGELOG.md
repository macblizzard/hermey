# Changelog

All notable changes to Hermey are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions are the app's build versions.

Each release's section may carry both its release notes and the per-change entries
recorded as the work landed; entries before 0.1.610 were given their version headings
from the repository's history and the published release pages.

## [0.1.697] — 2026-11-27

### Added
- **The task board is on screen.** Every long task a bot runs already records a `todo_list` — the app never drew
  it. A strip now sits directly above the composer on both the phone and the Mac: `Tasks 3/12` with one row per
  item, ticking live as the bot updates them, opening itself while something is in progress and folding to
  `Tasks 12/12 · done` when it is finished. Tap to open or close it. Nothing is drawn when a bot has no board.

## [0.1.696] — 2026-11-27

### Security
- **A tag name can no longer run code in CI.** Every workflow that put a `github.*`, `inputs.*`, `steps.*`,
  `env.*` or `secrets.*` value inside a `run:` script now passes it through `env:` and quotes it; a workflow test
  fails the build if one comes back. The release job had `contents: write`.
- **Plaintext sockets are refused off the loopback.** Pairing used to test `URLComponents.host` against
  `"[::1]"`, which never matches, and a decoded pairing address could carry `ws://` into the API, socket and
  local-computer URLs. One loopback predicate now decides, a remote address is upgraded to `wss://`, and the
  fallback that would have re-emitted the plaintext URL is gone.
- **The insecure-TLS escape hatch is explicit and loud.** `--insecure` prints a warning when parsed, nothing
  retries it on error, and `fetch` refuses anything that is not http(s).
- **Reasoned allowlists** so the next audit is signal rather than noise: gitleaks for Sparkle's *public* key and a
  UserDefaults key name, osv for the unmaintained-only `unsafe-libyaml`, semgrep for git blob SHA-1 and test
  `eval`, bandit by path for the test harness. Re-sweep: zero unsuppressed high/critical.
- **Dependencies**: `url` 2.5.9 (stack overflow on nested `blob:` URLs), `rusqlite` 0.43 with
  `libsqlite3-sys` 0.40 and a current SQLite (CVE in the bundled copy), `serde_yaml` → `serde_yaml_ng`.

### Changed
- **`hermeyd` 0.8.27** — carries the SQLite and URL fixes; deploy this one with the app.

## [0.1.695] — 2026-11-27

### Added
- **Attachments travel between your devices.** A photo sent from the phone was stored on the host and left
  behind as a bare path, so the Mac showed a sentence with a filename in it. Now an `@image:` reference draws as
  a thumbnail you can tap to open full size, and a `@file:` reference draws as a chip with its name, type and
  size — on the phone and on the Mac, in the same conversation, both directions.
- The host serves those files itself (`GET /v1/attachments`), scoped to the profile's own `images/` and
  `attachments/` folders, refusing traversal, other profiles, symlinks and anything over 32 MiB; bytes are
  cached per device so a relaunch still draws what it has seen.

### Changed
- **`hermeyd` 0.8.26** — carries the attachment route.

## [0.1.694] — 2026-11-27

### Fixed
- **The update prompt appears without pressing anything.** A cold start already asked, but on iOS "starting the app"
  is nearly always a resume, and the resume path was throttled to one check a day — so a release published after
  the last check stayed invisible until tomorrow. Launch and every return to the front now ask (a repeat within
  15 minutes of the same session is still skipped).
- **Check now can no longer say "up to date" when the feed has something newer.** A stored "highest offered build"
  was allowed to refuse a fresh document; it now cannot veto anything. The row also stopped using one sentence for
  six different outcomes — up to date, offered, newest entry not installable here, feed unreachable, declined, or
  already in flight are each named, and every check logs `advertised=… installable=… installed=… offer=…`.

## [0.1.693] — 2026-11-27

### Fixed
- **The voice loop now finishes what you say.** The end-of-speech level was measured against an estimate of
  the room taken from your own first words, so it could sit *above* your normal speaking voice and no sentence
  ever ended. The room is now tracked continuously from quiet audio only, and the boundary is set below the
  voice actually heard — 0.45 × the voiced average, floored at 60 — so a pause always ends the sentence.
- **Stopping by hand keeps the sentence.** Tapping stop mid-sentence now transcribes and sends what was heard
  instead of throwing it away, and a 20-second ceiling ends a runaway utterance.
- **"Stop" is heard wherever the audio is transcribed.** The spoken stop phrase is tested first in the one
  shared transcription path (pause, ceiling, manual stop) and sends nothing — before this it could only be
  recognised after an utterance had ended, which on the phone never happened.
- **The update feed is read from the release asset**, whose CDN keeps no 10-minute copy, so a fresh release is
  visible immediately rather than after the GitHub Pages edge window.

## [0.1.692] — 2026-11-27

### Changed
- **One audio control in the composer.** A tap starts the hands-free conversation, a hold dictates one
  message into the draft; the first time you see it, one dismissible line says so. The second glyph is gone.
- **Voice is on the keyboard.** Settings ▸ Shortcuts gains **⌥⌘V** (start/stop the conversation) and
  **⌥⌘D** (dictate into the draft), both rebindable like every other row.

### Fixed
- **The iPhone's voice loop can now finish a sentence.** The last build fixed its ears by moving to the same
  audio-session mode as the working dictation mic; this fixes the other half — the end-of-speech level sat
  below the room's own noise, so an utterance never ended and no turn was ever sent. The level is now derived
  between the measured floor and speech, and the log names what it used.
- **The update prompt goes straight to the newest build.** The feed is fetched cache-busted (GitHub Pages
  answers with a 10-minute edge copy and ignores `no-cache`), and an offer is always the newest installable
  build — never the next one above what you have, so a device several versions behind upgrades in one hop.
- **`hermeyd` 0.8.25** — the release tag now only points at a commit whose manifest matches it (0.8.24 was
  published from a commit that still said 0.8.23, which is why the host installed it and rolled itself back).

## [Unreleased]

## [0.1.691] — 2026-11-27

### Fixed
- **The iPhone's voice loop should hear you now.** Its audio session ran in `.voiceChat` mode, the system
  voice-processing input, while the dictation recorder beside it — which works on the same phone — uses
  `.spokenAudio`. The loop now uses the working mode, tunes its listening floor for a quiet stream instead of a
  fixed constant, and logs the RMS and peak of its first five blocks so a silent stream is visible rather than
  guessed at. The Mac's numbers are unchanged.
- **The parked-glass note no longer carries a tailnet address** (it failed the repo's secret scan).

## [0.1.690] — 2026-11-27

### Fixed
- **The iPhone's voice loop says what it is doing, and its control looks like what it is.** It drew a plain
  microphone while listening, one glyph away from the dictation mic beside it — and when the loop failed to start
  the strip read "Voice stopped" with no reason, so a failure looked like nothing happening. The loop now stays in
  the waveform family in every state, a failure prints its sentence, and every step of the start path is logged
  under `voice`: permission, audio session, input format, tap, engine, first buffer, voice detection, endpoint,
  transcription and each phase change.
- **The bundled agent-cards skill matches the shared copy again** (it had drifted, which failed a guard).

## [0.1.689] — 2026-11-27

### Added
- **Voice conversations, hands-free.** One tap on the waveform in the composer opens the microphone and keeps it
  open: you speak, your words appear as a message, the answer is spoken back, and it listens again. Talking over
  a reply stops it and becomes the next turn, a spoken "stop" ends the loop, and the microphone is released on
  every exit — toggle off, leaving the bot, backgrounding, a call taking the session, or a failed request.
  The device does the endpointing (600 ms of silence ends an utterance, a cough is not a turn); the host
  transcribes with Groq and speaks with ElevenLabs, sentence by sentence, so the first words arrive while the
  rest is still being generated. Built on the same machinery as Hermes' own voice mode: a rolling-floor barge
  detector with quiet-room calibration, a Whisper-on-silence filter, a strict stop phrase, a self-echo guard and
  markdown-to-prose projection.

### Fixed
- **Updating a bot's avatar reaches its pet.** A save of a drawn avatar left the desktop pet showing the face it
  was created with, because only classic-face changes refreshed it; the pet now follows the saved avatar. (It
  follows the save, not the unsaved draft — in-window surfaces follow the draft, surfaces outside the window
  follow the save.)
- **The glass halo no longer bands**, and hermeyd is 0.8.23 with a published tag for this release.


## [0.1.688] — 2026-11-27

### Fixed
- **The halo's fade no longer bands.** The glow was added after the shader's dither, so it stepped into the 8-bit
  target; it now goes through the same half-bit dither and the far field varies by a single level.

### Changed
- **Hermeyd 0.8.22**, and every release now publishes a matching `hermeyd-v<version>` tag, so the host's update
  check can never again report "could not check" because the feed had no hermeyd release to compare against.

## [0.1.687] — 2026-11-26

### Changed
- **Brighter faces, with a little glow.** The glass body is lit further on dark surfaces and carries a short
  tinted halo plus a faint inner luminescence, so a face pops on the pane instead of sitting dark behind its rim.
  The eyes keep their contrast floor; a light page looks as it did.

### Fixed
- **A preset changes the shape, not just the caption.** The editor's preview and the header now draw the draft's
  own body, and the drawing cache is keyed by that body, so choosing Mug actually gives you a mug.

## [0.1.686] — 2026-11-26

### Fixed
- **No more black faces.** 0.1.685 let the glass transmit whatever it sat on, so over the app's near-black
  pane the body became the background — black — and the eyes sat at 1.1:1 against it. The material now carries
  its own hue on top of what shows through, scaled by the backdrop's luminance: over the pane a face is a dark
  *coloured* glass (measured on the 200 pt render: a saturated terracotta body with black eyes at better than
  3:1), over a light page it stays bright and transmitting as before.

- **Bot faces are coloured glass on a dark page again, not black shapes.** 0.1.685 made the body
  transmit the surface it is drawn on — brighter and truer over a light page, and black over the bot
  list, because transmission *multiplies* its backdrop: on the app's own pane (`#1E1E1E`) every bot was
  its hue multiplied by nothing, and the eyes fell to 1.1:1 against the pane, so the faces read as
  outlines and nothing else. The body now also *adds* its own colour, at a level that is a function of
  the page's own luminance: nothing on a light page (0.1.685's transmission is untouched, and measured
  identical), the material's full `jewel` hue on a dark one. Measured on the shipped amber body: the
  centre sits at 0.173 relative luminance against the pane's 0.013 (hue 16°, chroma 0.67) and the eyes
  read 3.9:1, up from 1.1:1; on the light page 0.594 and 11.2:1, unchanged. The desktop pet, which
  cannot name a page, is bit-for-bit what it was.

## [0.1.685] — 2026-11-26

### Changed
- **The glass transmits, and it is brighter.** The body no longer sits on an invented studio: its plate, its
  twelve interior slices, its back wall and its internal focus all take the colour of the surface the avatar is
  drawn on (the theme's own pane and page tokens). Absorption came down so light gets *through* it — at 200 pt
  the path passes 94/55/31 % instead of 90/32/19 % — and the softbox is scaled by the room's own light instead
  of being nine times brighter than it. Over the pane the centre sits within 10 % of the background instead of
  163 % above it; over a light page it is bright rather than dim, and the eyes keep their contrast.

### Added
- **Settings ▸ Shortcuts.** Every keyboard action in one list — Navigation, Conversation, Message, Window —
  with a recorder, a per-row reset and Restore Defaults. The Mac menus read the same list, so a rebound key
  takes effect without a relaunch. A combination another action already owns is refused and named; macOS's
  own combos (⌘Q, ⌘W, ⌘,) cannot be taken; ⌫ clears a row.
- **Message Actions… (⌘⇧M)** opens the row menu from the keyboard for the message Tab is on.

- **Rebindable keyboard shortcuts, in Settings → Shortcuts.** Every key the Mac app answers to is now
  one row in one registry — its id, what it does, which menu it lives in, and the combination it holds —
  and the menu bar, the ⌘K palette's hints and the new **Shortcuts** tab all read that table instead of
  spelling combinations of their own. Each row has a recorder (press the field, then the combination;
  Escape cancels, ⌫ clears it), a per-row `↺` and one **Restore Defaults**; bindings are stored per app
  in `UserDefaults` (`hermey.shortcuts`, overrides only, unknown ids ignored) so a build that adds an
  action needs no migration. Two actions cannot share a combination — the row that tries names the one
  that already has it and nothing is written — and macOS's own ⌘Q, ⌘W and ⌘, are refused outright. A
  rebind applies immediately: SwiftUI's `.keyboardShortcut` cannot be rebound at runtime, so an AppKit
  pass writes `NSMenuItem.keyEquivalent`/`keyEquivalentModifierMask` for the real items on every change
  and again on activation. Three verbs are new to the keyboard and were only ever buttons or hints
  before: **Copy / Edit / Delete Last Message** (⇧⌘C, ⌥⌘E, ⌘⌫), **Next / Previous Bot** (⌥⌘↓, ⌥⌘↑), and
  **Refresh Conversation** (⌘R), which the palette had advertised for months with nothing bound to it.
  The pane is Mac-only: the phone has no hardware keyboard to bind, so it has no such screen.

### Changed
- **The ⋯ under every message is gone.** The right-click menu on the Mac and long-press on the phone carry
  every verb; rows are tab stops with a quiet hairline instead of a focus ring.

### Fixed
- **The bot settings header draws the face.** It drew a stale snapshot (blank for a bot with no classic face);
  it now shows the bot's own avatar, and while the Avatar tab is open it follows the draft as you pick.
- **The small face on the working line is 15 % larger**, hung off the text baseline so the row does not shift.

- **The settings header now wears the face you are choosing — and shows it at all.** The bot's avatar
  beside its name in the Mac bot-settings sheet and on the iPhone settings screen was resolving the
  *stored* face only, so with the Avatar tab open you picked Hourglass, the 200 pt preview became an
  hourglass, and the head beside the title stayed on the Cat you had saved last week — which reads
  exactly like "the presets do nothing". It also depended on the avatar library arriving through
  `environment.botAvatars`, which a presented sheet is not guaranteed to inherit, so for a bot whose
  only face is a drawn document it drew nothing at all. Both heads now draw the editor's own draft
  (the editor reports it through `onFaceChange`, so the head and the preview cannot disagree) and,
  before that tab opens, the sheet's *own* copy of the host's document — body, colour and material
  together, through one new `document:` door on `BotAvatarView` that takes precedence over the
  environment. One size for both platforms (`BotAvatarSize.settingsHeader`), still and static. The
  twelve presets were already writing the whole definition — that path is now pinned by a test that
  fails if a preset ever writes only the eyes — and the strip's six-column grid wraps, so all twelve
  are on screen.

- **A bigger face on the working line.** The small avatar that waits beside the "◉_◉ deliberating…"
  status phrase — the same row on both shells — was 16 pt and read as a dot. It is 15 % bigger
  (`WorkingStatus.avatarSide`, one constant), and the row is aligned on the text's first baseline so
  the taller face hangs off the words instead of moving them.

## [0.1.683] — 2026-11-26

### Fixed
- **The glass stopped banding.** Its interior was read from a chamfer transform of the filled raster — whole
  pixels, biased by edge angle — so the shader was refracting a staircase and every near-vertical edge came out
  striped. The field is now computed analytically from the silhouette path, once per size change (about 35 ms at
  200 pt on a 2x surface), and the body is smooth at 200, 48 and 24 pt.
- **Thicker glass now behaves like it.** A bounce term follows the ray's own optical path, the wall junction
  carries a real refracted line instead of a streak, and the caustic's landing, width and brightness come from
  the body's measured thickness — the thin flanks and corners cast hotter and tighter than the belly.

## [0.1.682] — 2026-11-26

### Added
- **The bot list breathes now.** Idle faces in the sidebar float too, driven by one shared 3 Hz clock: 1.6 pt of
  drift on a 38 pt face, roughly what a single hovered row used to cost. The timer stops when the window is not
  key, when the panel is collapsed, when more than 32 rows are on screen, and under Reduce Motion; a row that
  scrolls away settles to rest.

## [0.1.681] — 2026-11-26

### Added
- **Idle avatars float.** A gentle two-way drift, ±2 % of the avatar's side over 4.2 s, with a per-avatar phase
  offset so a column of bots is out of step. It rides the clock the breathing already uses, adds no timer and no
  layer, and Reduce Motion freezes it. Every other state draws exactly as before.

### Fixed
- **Settings ▸ About now tells the truth.** Check now built its URL with a literal `%3F` instead of a query, so the
  host answered 404 and the app swallowed it silently — which is why the row sat on a stale 0.8.9 until a hermeyd
  restart forced a reconnect. The press now asks correctly, logs one line, reports a failure on the row, and the
  version shown is always the host's own `current`. A published release the host has not offered reads as news.

## [0.1.679] — 2026-11-26

### Added
- **Edit a bot's memory from its settings**, on Mac and iPhone. A Memory pane lists the two documents every bot
  actually reads (`MEMORY.md`, `USER.md`) with their character budget, opens them in a plain text editor and saves
  through new device-authenticated routes. A save is one atomic rename at the original mode, confirms once, and is
  refused before it would exceed the bot's own budget — never truncated.
- `hermeyd` **0.8.14**: `GET/PUT /v1/bots/{profile}/memory[/{name}]`, name-matched against two fixed documents.

### Fixed
- **The app no longer crashes on launch.** A glass body whose view had no size yet divided by zero, the distance
  field became non-finite, and converting that to `Int` trapped on the main thread. The mask now refuses a surface
  with no extent and clamps every value.

## [0.1.677] — 2026-11-26

### Added
- **The pet's callout is a small chat.** Tap the pet to open it, type, and the bot answers below; click away and it
  hides but the thread is kept, and a new message from the bot opens it again by itself. Answers stay to two
  sentences, the thread is capped at 20 messages, and at the cap the field greys out with a **New** button.
- `hermeyd` **0.8.13**: the pet ask carries its brevity rule (`PET_BREVITY`).

### Changed
- **Glass has volume.** The body is raymarched as a solid: 12 interior slices, an elliptical edge bevel that reads
  as two lines, a form-following highlight, exit refraction and full-weight TIR, and a caustic under the base.
  A proof render over a checkerboard shows the pattern magnified through the middle, compressed at the bevel and
  folded near the wall. Upstream's own `renderer.ts` geometry is the source of every constant.

## [0.1.676] — 2026-11-26

### Added
- **Glass is a real surface now.** On the app's own drawing (Mac window, iPhone) a glass avatar is shaded by a
  Metal pass — Fresnel, a key and a rim softbox, an internal caustic, refraction and Beer-Lambert absorption —
  with the terms and constants taken from open-bot-avatar's own glass shader. The painted glass stays as the
  fallback the platform chooses (Reduce Transparency, a very small size, previews, the Live Activity).

### Changed
- `hermeyd` **0.8.12** (version bump with the app; no host change).

## [0.1.675] — 2026-11-26

### Added
- **The avatar renderer now follows open-bot-avatar 0.5**: marks are values a pose carries, a state can be a
  definition of your own (an id and a pose function, eased in and out like a built-in), `done` celebrates inside
  a nine-ribbon cage on three hoops, and the eyes morph between shapes instead of swapping inside a blink.
  Every count, angle and easing is upstream's, quoted in the source.
- The eight states you already had are untouched by this: no mark replaces a face, and no state shrinks the body.

### Changed
- `hermeyd` **0.8.11** (version bump with the app; no host change).

## [0.1.674] — 2026-11-26

### Fixed
- **Edit and resend, and Delete now actually run.** The confirmation appeared and then nothing happened: the
  alert's dismissal cleared the pending action while the button was still being dispatched, so the verb read
  nothing to do. The alert now hands its own presented action back, on both the Mac and the phone.

### Changed
- `hermeyd` **0.8.10** (version bump with the app; no host change).

## [0.1.673] — 2026-11-26

### Added
- **Edit and resend, and delete.** Any message's menu — right-click on the Mac, long-press on the phone —
  now has **Edit and resend** on your own messages and **Delete** on any of them. Edit prefills the composer
  with that text; sending retires it and everything after it and runs the edit as a fresh turn. Both ask
  once, in a card that says exactly how many messages are involved, and both are withheld while a turn is
  still streaming.
- `hermeyd` **0.8.9**: `POST /v1/messages/delete` and `POST /v1/messages/truncate`. They refuse unless the
  engine says that conversation is idle, close the session first so nothing keeps serving the old copy, and
  then *retire* rows (`active = 0, compacted = 0`) — the same write the engine's own undo makes. Nothing is
  ever deleted from the database.

- **The bot's own face on the Live Activity — and it moves.** The Lock Screen card and the island's
  expanded leading slot now draw the *same* avatar as the chat header: the same renderer, the same
  eight-state motion, so a thinking bot leans and looks up on the Lock Screen instead of showing a
  generic speech bubble, a blocked one stares back, and one on the computer leans aside with its eyes
  on the screen. The drawing is compiled into the extension from `HermeyUI`'s own `OpenBotAvatar`
  sources — one implementation, two processes, the arrangement `BotStateWord` already had — and it is
  resolved from the definition the activity carries, through `BotAvatarLibrary` and the same document
  initialiser the host's answer goes through, so there is no bitmap and nothing is decoded per frame.
  The pose is `OpenBotAvatarState`'s, driven by `TimelineView(.animation)` at the app's own 10 Hz;
  an Always-On Lock Screen or a stale card holds the stance rather than asking for frames the system
  will not composite. A bot with no drawn avatar keeps exactly the card it had — the phase's symbol,
  at the size it always was. The compact pill and `minimal` keep that symbol too: a face below the
  avatar's 24 pt floor is mud, and its width would widen the island.

## [0.1.672] — 2026-11-26

### Added
- **Edit a vault item**: rename it and replace its value from the vault pane on Mac and iPhone. The value
  field starts empty and says "leave blank to keep the current value"; the host never sends a stored secret
  back, and a failed write leaves the item exactly as it was.
- `hermeyd` **0.8.8**: `PATCH /v1/vault/{name}`, write-only, one atomic store write.

- **Edit a saved secret, and never see it.** Every row in **Settings → Vault** — the Mac's tab and the
  phone's screen — now has **Edit**: rename the item, replace its value, or both, in one save. The value
  field starts empty and says *"Leave blank to keep the current value"*, because there is nothing to
  prefill it with: no route returns a stored value, and the new `PATCH /v1/vault/{name}` answers with the
  item's new name and two booleans and nothing else. A rename and a replacement are one write
  (`secrets::edit`, through the same temp-file-then-rename an add uses), so a rename cannot land without
  its value or the reverse. A name another item already holds is refused (409) instead of swallowing it,
  editing a name nobody saved is a 404, and an edit that would change nothing is a 422 rather than a silent
  success. Adding is untouched — a new item still comes from the masked `store` card, where a blank value
  is still refused — and the labels a row shows move with a rename rather than being copied to it.
  `hermeyd` **0.8.8**.

### Changed
- **The bot list row has no ⋯ any more.** Hover, selection and keyboard focus all showed it over the same
  menu the row's right-click already opens, so it is gone; the hover fill and hairline stay.
- **The group-chat composer stopped explaining itself**: no "⏎ send · ⇧⏎ newline" line, placeholder is
  just "Message the group". Direct messages are unchanged.

## [0.1.671] — 2026-11-25

### Fixed
- **Long messages collapse at 50 lines**, on both Mac and iPhone, with a button that says
  `Show full message · 32 more lines` and then `Show less`. This now covers the shapes that slipped through
  the first version — delegation and system rows, tool results and reasoning — because those were exempt.
  The collapsed row does no markdown work at all: no parse, no per-span styling, no measurement.
- **The conversation no longer bobs when a sidebar opens or closes.** The transcript was re-wrapping at the
  animated width, the composer's height re-fed the foot inset, and the viewport probe took every width change
  for a new message and yanked the scroll — four times per slide. The column resolves its geometry once at
  the final width, the probe follows height only, and one curve (0.18 s) owns both panes.

### Changed
- `hermeyd` **0.8.7** (version bump with the app; the host code is unchanged from 0.8.6).

- **Fifty lines, then a button — on every kind of message.** The scroll freeze the 0.1.670 clamp was
  for came back with the same two screenshots: a bot's reply whose every identifier is inline code,
  and the `[ASYNC DELEGATION BATCH COMPLETE — deleg_…]` system row. Neither was a 20,000-character
  log, so neither tripped the old rule — and the rows that did get clamped were only the plain-prose
  ones, because anything carrying a `::` marker was exempt. Now every body a row draws goes through
  one decision and one view (`TranscriptClamp.plan`, `ClampedBody` in `HermeyUI`, shared by the phone
  and the Mac): past **50 lines**, **4,000 characters** or **40 inline-code spans**, a message shows
  its first fifty lines as plain text with **Show full message · 312 more lines** beneath it, which
  becomes **Show less** when opened. The collapsed row parses no markdown, styles no span and
  measures no table — the markdown a reply always had is built only when you ask for it, off the main
  actor, and the opened row stays open while you scroll. System, reasoning, tool-run and delegation
  rows and their cards clamp too; the only exemptions are the four small structured cards (approval,
  draft-email, infographic, secure-entry), enumerated in one place with the reason each is there. No
  message is truncated: the full text is kept, selectable, and what Copy copies.

## [0.1.670] — 2026-11-25

### Fixed
- **Scrolling a long chat no longer freezes the app.** Grouping and the visible rows were rebuilt from the whole
  transcript on every page that landed (4.5 M rows walked in ten seconds of scrolling); they are spliced now, so a
  page costs its own 400 rows. Tool payloads are parsed once, not twice per frame.
- **One huge log message no longer hangs a row.** Anything over 4,000 characters or 60 lines renders as a 24-line
  preview with "Show full message", which parses on demand instead of drawing hundreds of markdown blocks.

### Added
- **View Log copies a portion**: last 100 / last 500 / shown / all, each respecting the active filter, with the
  pool size in the label.
- **Send log to host**: one tap writes the same bytes to /var/log/hermey/ on the host (0640, never overwritten,
  2 MiB cap) and shows you the path — so a report comes with a pointer instead of a paste.

- **Copy a portion of the log, or leave the whole thing on the host.** View log's Copy is now a menu of
  four — **Copy last 100 lines**, **Copy last 500 lines**, **Copy shown**, **Copy all** — each labelled
  with the size of the list it would take ("Copy last 100 lines (of 812)"), and all four narrowed by
  whatever level, category or search the sheet is filtered to, so a copy is the tail of what is on
  screen rather than the whole file. The owner asked for exactly that: *"would be better if i could just
  copy a portion of the log like last 100 lines and so on instead of copying the whole thing and paste
  here on chat."* Beside it, **Send log to host** posts those same bytes — plus the device name, app
  version and build, OS, capture time and active filters — to a new `POST /v1/client-logs` on the host,
  which writes `/var/log/hermey/client-<device>-<UTC minute>.log` (0640 root:root, one file per device
  per minute, never overwritten: a second upload inside the same minute answers 409 rather than
  truncating) and answers with the path the sheet then shows. It is a plain bearer POST, not the relay
  socket, so a busy conversation cannot delay it; 2 MiB on both ends with a sentence saying so; a
  failure (403, 409, 413, unreachable) is shown in the sheet, which stays open. Nothing is ever uploaded
  on its own — *"wouldn't it better if u save the log on server side as well so that i wont have to
  paste the whole log for u to investigate?"*

### Changed (hermeyd)
- `hermeyd` **0.8.6**: the client-log upload route, and `session.set_hidden` is allowed through the bridge so the
  2,000-message roll actually takes effect.

## [0.1.669] — 2026-11-25

### Fixed
- **A long Bot Chat opens.** Your cody chat was 6,778 messages and the host built all of it — 7.5 MiB in one
  frame, ~10 s — while retries stacked more renders on top, which is how an open became a 120-second wait. The
  host now pages the reply from its text before parsing it (434 ms → 92 ms on a 3.4 MB resume), answers duplicate
  resumes from one render, and the phone paints its own disk copy before any round trip.
- **The launch sweep no longer queues behind your tap.** Opening a bot cancels the background warm-up mid-flight
  instead of waiting its turn.
- **The pane says what it is doing** when the host is slow: "sending this chat's history — 14s · every message is
  kept", with a Retry bar, instead of a silent spinner.

- **A long bot chat opens on its newest rows at once, and scrolling back does not mean forty taps.**
  The disk copy of a chat was read *after* two round trips — `model.options` and `session.list` — so a
  cold tap on a chat with thousands of rows showed "Opening…" for the length of both before the cache
  was even opened. It is now the first `await` of the open, off the main actor and keyed by the id
  this device remembered, so the newest rows are on screen before either call is made and the resume
  replaces them when it lands. The launch sweep — which warmed up to 24 bots on the one socket, 150 ms
  apart — is now a task the model owns, and a tap cancels it mid-flight instead of waiting for the
  in-flight warm and then the rest of the roster. Behind a windowed resume the app fills older pages
  itself (a page is a read of the relay's own copy, so no agent work), bounded, silent and
  cancellable, and one "load earlier" is 400 rows rather than 150. The adopted transcript no longer
  joins the attachment vault on the main actor — that per-row pass over every row is detached now, and
  the rows are on screen while it happens.

- **The host pages a resume before it reads it.** The relay used to parse the whole `session.resume`
  frame into 6,778 rows, slice the newest page off the end, and measure every row a second time to
  cache it. It now borrows the message array as raw text, counts it (which is what `history.total`
  reports), parses only the newest page, and keeps the rest as the bytes it arrived as for
  `session.history` to page from. Measured on a synthetic 6,778-row / 3.4 MB resume in a debug build:
  **434 ms → 92 ms**. The device cache keeps 2,000 rows per chat instead of 500, and a trimmed
  transcript keeps its paging cursor (moved forward by the rows it lost) instead of dropping it.

### Added
- **Start a new chat after** — Settings → Chat on both apps, 1,000 / 2,000 / 5,000 / Never, default 2,000. At the
  ceiling the bot's chat rolls to a fresh conversation and the old one moves to **Previous conversations**, with
  every message kept and its count and date shown.
- **A vault panel in settings** on the Mac and the iPhone: saved secrets by name only, add through the masked
  sheet, delete with a confirmation.

- **Your host has a vault, and Settings now shows it.** A new **Vault** tab on the Mac and a **Vault**
  row under **Settings → Secrets** on the phone list the secrets the host holds — by name, with where
  each is for and when it was added — and let you add one or delete one. The pane never shows a value:
  the row type on the wire (`GET /v1/vault`) has no field to carry one, and there is no reveal control
  to press. **Add a secret** asks the host for the same `store`-mode card a bot's request makes and
  opens the *same* masked sheet, so a value still enters the host exactly one way; **Delete** removes
  the name from the vault (ask first, and a refusal is shown rather than swallowed). A host that cannot
  be reached says so instead of drawing an empty vault, and an empty vault says what the vault is for.

### Changed (hermeyd)
- `hermeyd` **0.8.4**: pages the resume from its text, parks duplicate resumes, keeps 2,500 rows of device cache
  with its cursor, and serves the vault's name-only list.

### Changed
- **A long chat opens, and a slow open says so.** cody's Bot Chat holds 6,778 messages (~4.5 MB of
  text) and took long enough to open that the phone's `session.resume` timer fired at 120 s and the
  pane stayed empty. Measured on the host: reading the rows is 0.03 s; the engine's *display
  projection* of the whole lineage is 6.2–9.2 s per resume, 7.5 MiB in one frame, and three sent
  together answered at 6.2 s, 12.6 s and 18.5 s because the gateway renders them in turn. The app
  retries an open it is waiting on, so a 6 s answer became a 120 s timeout. Now one conversation
  being resumed is one engine request — a repeat is parked and answered from that reply, on both
  the host (`hermeyd`) and the client — and the pane counts the wait out loud ("the host is sending
  this chat's history — 14s") with a Retry beside it, instead of spinning in silence. Nothing is
  trimmed: the phone still receives the newest page with `history{total,cursor}`, and every older
  message stays reachable by scrolling back. A windowed *resume* on the engine side still needs an
  upstream change (`omit_messages` is only an empty ack), so a cold open of a chat this size is one
  render, not instant — but it is one, not one per retry.

## [0.1.668] — 2026-11-25

### Added
- **Infographic cards, for real this time.** 0.1.667 announced them and did not contain them: the branch was
  merged before its work was committed. This build carries the kind, the host validation and the shared layout.
  A short query comes back as a card with one real picture and a caption, three to eight facts, the number that
  matters highlighted (a price, with seller and availability), one link and a source.

## [0.1.667] — 2026-11-25

### Added
- **Infographic cards.** A short query can come back as a card with one real picture: hero image with a caption,
  three to eight facts, the number that matters in a tinted block (a price, with seller and availability), one
  link and a source. The layout is shared by the Mac and the iPhone; a dead image falls back to the caption.

### Changed (hermeyd)
- `hermeyd` **0.8.3**: the infographic schema and its named rejections.

## [0.1.666] — 2026-11-25

### Changed
- **Secure entries keep the secret.** The credential card existed and worked, but it handed the value to the bot,
  which is no use for an API key and the wrong place for a password. A card can now say *store*: the value goes
  to a vault on the host, and the bot gets back a name it can use later (and fill into a page by name) — never
  the value itself.
- **Every field but a username is masked.** Masking used to key off the literal field name "password", so an
  API key was drawn in clear text.
- **The card says where it goes**, instead of promising a page it did not have.

### Changed (hermeyd)
- `hermeyd` **0.8.2**: the vault, the masked fields, the store path, and the name-resolved fill.

## [0.1.665] — 2026-11-25

### Fixed
- **The Mac's message menu icons are visible.** They were there in 0.1.664, tinted into the dark menu: a
  template image is re-tinted by whatever draws it, and inside a menu that tint followed an appearance the app
  was not showing. The glyph is now coloured for the menu's own appearance and the menu draws in the app's.

## [0.1.664] — 2026-11-25

### Fixed
- **The Mac's message menu shows its icons.** Every row carried a glyph already — the iPhone drew them — but
  SwiftUI's macOS menu builds its items from a button's title and dropped the image, so only `Share` (a system
  link) was marked. The menu is a real `NSMenu` now, with each item's image set from its row's own symbol, popped
  on right-click and reachable from the keyboard with the `⋯` on the action line.

## [0.1.663] — 2026-11-25

### Changed
- **The composer's `+` is a two-entry menu again: Photos… and Files…** The single panel could not reach the
  Photos library, and that is where the pictures are.

### Fixed
- **The sidebar's `＋` hover, again.** The tracking area was still at the mercy of the menu's own cell deciding
  what the view in front hears; the pointer is now sampled from the window's event stream, so nothing in front
  can hide it.

## [0.1.662] — 2026-11-25

### Fixed
- **Waiting and blocked avatars wear their own eyes.** Blocked drew at 32% behind a bang mark and waiting turned
  its eyes into a slit; every state now draws the resting silhouette with a normal face and differs only in
  motion. Blocked is the stillest state with an unblinking stare and the deepest pulse; waiting leans and looks
  aside.
- **The sidebar's `＋` hover fires, and you can see it.** A borderless menu swallows SwiftUI's hover events, so
  the state never flipped; it now comes from an AppKit tracking area behind the button, and the fill, glyph and
  hairline all move.
- **Collapsing the panel no longer sends its toggle to the title bar.** It floats on the window's floor at the
  exact height of the panel's own bar, so the glyph does not move when the panel slides away.
- **The composer's `+` reaches your Photos library again.** The single file panel was the right idea, but with
  the panel taking any file the Photos source disappears from it — the panel now carries its own `Photos…`
  button and hands over to the system photo picker.

## [0.1.661] — 2026-11-25

### Fixed
- **Reactions travel between devices.** A thumbs-up on the Mac now shows on the iPhone (and back) without
  reopening anything: the app was only re-reading reactions from one code path its normal open never took, and
  it filed them under an id the other device could not ask for. Both fixed, with a live push and a refetch on
  open as the fallback.
- **Thinking avatars are the same size as every other state**, with normal eyes — they used to shrink to 42%
  and lose their face to a three-dot mark.

### Changed
- **The token count is always there.** Each bot remembers the last number the host reported, so the composer
  shows it the moment a conversation opens instead of only after a turn. A brand-new bot still shows the model
  alone.
- **The sidebar's `＋` has a hover state and takes every click** — a full-width title-bar drag area was
  swallowing the press.
- **The desktop composer's `+` opens one file panel** for any photo or file instead of a two-item menu.

### Changed (hermeyd)
- `hermeyd` **0.8.1**: the reactions route's coverage, including two devices agreeing on one reaction and on
  its removal.

## [0.1.660] — 2026-11-25

### Added
- **The bubble takes the bot's colour.** A bot's own messages are tinted with that bot's avatar colour — so a
  green bot is green in the list, in the header and in its bubbles — with the ink measured against the fill for
  contrast. Your own bubbles are unchanged.
- **The classic faces are back as a choice.** The Avatar tab has a CLASSIC row of the eight original faces and
  colours: pick one and the bot wears exactly the face it had before drawable avatars, or customise one instead.
  The two never mix.

- **The Avatar tab offers the Classic faces again, beside your own.** A new **Classic** row — the
  eight bodies and palette colours this app already ships, as eight whole faces rather than a body
  picker and a colour picker that could disagree — sits under the custom presets, scrolls if the
  sheet is narrow, and says which of the two families the bot is on now. The two are alternatives in
  storage, not a pair: saving a Classic face clears the bot's drawn avatar (`definition`, `color`,
  `material`), and saving a preset or a Random pick clears the Classic face — one request either
  way, so a bot cannot wear a drawing that outranks the face you just chose. Reset clears both and
  leaves the face the bot's id derives. Nothing new is drawn: the faces are the existing tables, and
  the rakazo notice is untouched.

### Changed
- **Softer default shapes.** The twelve starting silhouettes are filleted — corners rounded by 5% of the shape's
  size — so they read softly at 26 pt instead of knife-edged. A definition you paste yourself is left exactly as
  you wrote it.

- **A bot's message is drawn in that bot's colour, not the app's.** One resolver
  (`BotAvatarTint.resolve`) now answers "what colour is this bot" — its drawn avatar's stored colour
  when it has one, its shape or photo face otherwise, the id's own otherwise — and every surface
  that shows a bot's identity asks it, so a green avatar no longer keeps the blue bubble its old
  shape face picked. Your own bubble is unchanged (the same 0.16 wash and 0.45 border, in the bot's
  colour, as before); a bot's *own* bubble — in a room, and a bot-to-bot message on both apps — is
  filled with its colour deepened on Midnight and paled on Parchment, edged in the colour itself,
  and written in the ink that measures best against that fill rather than in an assumed white. A
  bot whose avatar is nearly white on Parchment is the one face whose bubble is carried by its
  border alone.

### Fixed
- **Opening a bot on the iPhone is instant.** The attachment vault was read from disk inside the open (and again
  inside every transcript row's body), and the resume call queued behind the launch sweep — that was the 15–20
  second freeze. It now paints from cache, gives up with a Retry after 12 s, and repeated taps are ignored
  instead of pushing a second screen and crashing.

- **Opening a bot from the phone's list is instant, and tapping it again does nothing.** The 15–20 s
  "stuck, then it loads" was four things at once. A tap started a `Task` per press and every one of
  them pushed another conversation screen, so a tap storm during the push animation stacked a screen
  per tap and each screen ran its own capture/reset/resume against the one shared transcript — two
  of those interleave at every `await` and each reset makes the other's resume answer be dropped,
  which is the screen that never leaves "Opening…". The resume itself is answered on a 120 s client
  timer and queued on the host behind the launch sweep, which walks the whole roster one
  `session.resume` at a time, so the wait had neither an end nor anything to press. And on the main
  actor, painting a transcript joined the sent-attachment vault (a JSON read plus the bytes of every
  picture the chat ever sent) while every user row re-read the bytes of every picture it referenced
  *in its body* — a disk read per body pass, 25 a second while a turn streams. Now: one open at a
  time (`beginOpen` answers "no" to a second tap on the same row and cancels the open in flight for a
  different one), one screen per open, the cached conversation painted synchronously on the tap
  before any `await` and before the push, the vault join and its picture bytes memoised and run off
  the main actor, the row's reference join resolved once per row outside its body, the host given
  `openDeadline` (12 s) before the pane says so beside a **Retry** with the cached rows still behind
  it, and the launch sweep standing down the moment a person opens a chat.

## [0.1.659] — 2026-11-24

### Fixed
- **The composer's session row starts at the `+` button's edge**, not under the message text, and the token count
  keeps a clear margin inside the rounded corner instead of running to the card's edge.

## [0.1.658] — 2026-11-24

### Changed
- **The model and the token count now share a row, one at each end.** The count used to sit inside the model
  pill, so on a narrow phone the model name was squeezed to fit it. The pill holds the model and its chevron on
  the left, the context count sits on the right with its own width, and neither can shrink the other.

## [0.1.657] — 2026-11-24

### Fixed
- **The token count shows on the phone too.** A narrow pill used to drop the whole count and keep only the model
  name, so the number lived on the Mac and not on the iPhone. The count now holds its room and the model name
  truncates instead.

## [0.1.656] — 2026-11-24

### Fixed
- **The model pill lines up with the message.** It sat 8 pt left of the typed text because the composer row's own
  inset was missing from its leading padding.

## [0.1.655] — 2026-11-24

### Changed
- **No more blue focus rings.** macOS draws its keyboard-focus effect in the accent blue; the app's chrome never
  wears it. Every button, picker, toggle, menu and link now suppresses that drawing — and keyboard focus still
  works: a focused bot row and the composer's model pill show the app's own quiet fill instead.

### Removed
- The old Hermes-to-Rakazo parity tasklist (`docs/LOCAL_COMPUTER_PARITY.md`) and its test, which outlived the
  thing they tracked.

## [0.1.654] — 2026-11-24

### Fixed
- **The model pill sits under the text, not beside it.** On the Mac it shared the field's row between the
  paperclip and the placeholder, which read as part of the input; both apps now draw it on its own row beneath
  the field, lined up with where the text starts.

## [0.1.653] — 2026-11-24

### Fixed
- **The model pill in the composer is as tall as the buttons beside it.** It was collapsing to the height of its
  own text, which made it read as a slim bar next to the round attach and send controls.

## [0.1.652] — 2026-11-24

### Added
- **Two more materials.** Besides **Solid** and **Glass**, a face can now be **Matte** (no specular at all —
  felt or clay: a dark soft edge, a hint of grain) or **Metal** (a hard horizon line across the body, a narrow
  bright rim, no halo). Both were built as rows in the material table, so nothing else in the app changed.
- **Six more shapes, and a Random button.** The Avatar tab now offers twelve starting silhouettes (bottle,
  star, droplet, hourglass, book, mushroom join the first six), and **Random** rolls a shape, a material and a
  colour together — never the same combination twice.

### Fixed
- **Extra eyes while a bot thinks.** The thinking and blocked states drew their mark *and* the face's eyes,
  and the eyes never shrank with the body, so a small body sat between two full-size eyes. A mark state now
  gives the face up entirely, as the reference does.
- **The iPhone Lock Screen card's alignment.** Its two text rows had two different left edges (the phase
  symbol indented the second one) and the block sat low; they share one edge now and the block is centred.

### Changed
- **The row menu hides until you need it.** On the Mac the ⋯ on a bot row appears on hover, selection or
  keyboard focus and no longer reserves space — and hovering a row wakes its avatar for a small hop and a look
  toward the pointer.
- **Model and context moved into the composer.** They are one pill in the composer's own control row: the model
  name, how much context it is using, and a chevron. Click the pill to open the model picker.

## [0.1.651] — 2026-11-24

### Fixed
- **The ring around grouped bot faces.** A group-chat row drew a thin circle behind every face, which looked
  wrong around a square or cat-shaped avatar — a dark ring with gaps. It now only draws that circle for the
  old picture faces, and lets a drawn avatar be separated by its own outline.
- **Icons in the message menu.** Only *Share* had one. Select Text, Read Aloud, Add Reaction, Copy Message and
  the phone's Reply/Copy code block all carry their own icon now, in one consistent style.

### Added
- **The model and its context, at the composer.** Above the box on both the Mac and the phone: the bot's
  `provider/model` and how much of its context is used (`540k/1M Tokens`). It sits outside the text field, never
  covers or reflows what you type, and drops to the model alone on a narrow window.

## [0.1.650] — 2026-11-24

### Fixed
- **A notification icon is the avatar you chose.** Banners, the push relay's icon and the notification list
  used to show a bot's old shape picture even after you gave it a drawn avatar. They now render the avatar you
  saved — at rest, so it costs nothing per notification — and a bot without one keeps exactly the picture it had.

## [0.1.649] — 2026-11-24

### Added
- **Glass avatars.** A bot's drawn face now has a material. Choose **Glass** in the Avatar tab and the shape
  is lit like glass — a soft coloured halo, a vertical colour ramp, a form sheen, one specular streak, a
  bright Fresnel rim and a contact shadow at the bottom — instead of a flat fill. The rim and glow pulse with
  what the bot is doing, and the look holds at 26 pt in a list row as well as full size on the pet and in the
  editor. **Solid** stays the default, so nothing you already saved changes.
- **Motions that match the old face.** The drawn avatar used to only breathe; it now hops, tilts, flips,
  makes quick eye darts and squints while it works, on exactly the same clock and performance the picture
  avatars have — one motion language, not two.

- **A bot's face can be made of glass.** A new `material` on the avatar document (`solid` | `glass`,
  absent meaning solid) picks between the 0.1.648 flat body and the reference's lit one: a three-stop
  ramp, one specular streak, a Fresnel rim and a contact shadow, with the eight states as an accent
  on that material — the rim and halo pulse per state, and `blocked` calms the tint instead of
  turning it red. What is drawn follows the size: a 26 pt row gets only the ramp, rim and contact
  band, the 96 pt pet gets everything with its glow capped to the window's clear margin, and the
  editor's 200 pt preview adds the eye's catchlight. Materials are a table, not a flag — the renderer
  paints whatever spec the table holds and the editor lists it, so the next material is a row.
  Everything already saved is Solid: no migration, and the open-bot-avatar definition is untouched.

### Fixed
- **The avatar follows you everywhere.** A stored avatar only appeared in a few places: the bot settings
  header, the right-hand bot panel, transcript rows and the activity badges kept drawing the old face. All of
  them now read the stored avatar, so a change shows up without a relaunch.
- **One place to choose a face.** The duplicate *Choose bot icon* control is gone from the About tab (Mac) and
  the identity section (iPhone); the Avatar tab is the only place a face is picked.

### Changed
- `hermeyd` **0.7.0**: the stored face carries a `material`, validated on the way in — an unknown value is
  refused with the reason instead of being saved.

## [0.1.648] — 2026-11-24

### Added
- **A bot's own avatar.** Give any bot a generated face and it draws itself everywhere — the bot list, the
  chat header, and on your desktop as its pet. Bot settings has a new **Avatar** tab on both the Mac and the
  phone: pick one of six presets, paste a definition from the open-bot-avatar editor, or nudge the eyes and
  colour with a live preview. The shape is a small JSON definition (one outline plus where the eyes sit), so
  an avatar is portable and tiny. A bot without one keeps exactly the picture it had.
- **Eight bot states, one vocabulary.** idle, thinking, reading, working, computer, waiting, blocked and
  done. A finished turn now reads **Done** for a few seconds instead of vanishing, and a failed one reads
  **Blocked**. The same words drive the sidebar chip, the pet's badge and the Live Activity, so a face, a
  badge and your lock screen can no longer disagree.

- **A bot's own avatar.** Any bot can have a generated face, drawn natively in the app from a small JSON
  definition (one SVG path plus where the eyes sit — the open-bot-avatar format), edited in the bot's
  settings on either device: presets, paste a definition, or nudge the eyes and colour. It shows in the
  list row, the chat header and on the desktop as the pet. A bot without one keeps its picture.

- **Eight bot states with one vocabulary.** idle, thinking, reading, working, computer, waiting, blocked
  and done — a finished turn now reads *Done* instead of falling straight to silence, and a failed one
  reads *Blocked*. The same words drive the sidebar badge, the pet badge and the Live Activity.

### Changed
- `hermeyd` **0.6.0**: the bot icon document accepts a `definition` and `color` per bot, and refuses an
  invalid definition with the reason (so the editor can show it instead of silently saving).

- `hermeyd` 0.6.0: the bot icon document accepts a `definition` and `color` per bot, validated on the way in.

## [0.1.647] — 2026-11-24

### Added
- **Excel, Word and PDF files, both directions.** Attach a `.xlsx`, `.docx` or `.pdf` in either app and
  the bot gets its text — spreadsheets sheet by sheet, Word documents with their tables, PDFs page by page —
  with sensible limits and a note when a file was too big to include whole. They open from the transcript
  too: Quick Look on the Mac, the share sheet on the phone. And a bot can write a file and link it back:
  the reply carries a row you can open, downloaded from the host on press.
- **Pet questions run in their own session.** A desktop-pet question no longer rides the bot's whole
  conversation: it opens a dedicated, capped session per bot (60 rows, rotating) with the profile's fast
  model pinned. Same greeting, roughly 8× less input sent to the model, and a `/model` switch on the bot's
  chat can no longer drag the pet along. The pet's exchange lives in that session, titled *Desktop Pet*.

- **PDF, Word and Excel files are read by the host, and a file a bot writes comes back to you.** A
  `.pdf`, `.docx` or `.xlsx` (plus `.csv`/`.txt`) sent to a bot is converted **once** by hermeyd — the
  text layer page by page, paragraphs with their headings, every sheet's used range as pipe-separated
  rows — and arrives in the prompt as a labelled block (`--- attachment: budget.xlsx (sheet: Q4) ---`),
  so the phone, the Mac and every bot read the same document the same way. Bounds (50 pages, 2 000
  paragraphs, 12 sheets × 500 rows, 24 000 characters per document) are written into the text where
  they bite, every truncation is logged, and a scanned PDF says it has no text layer instead of
  pretending to be empty. The apps did not change how they send: the relay sniffs `file.attach`'s
  three types against their own bytes and refuses a mislabelled one with a sentence that names the
  file, while `GET /v1/attachments/{profile}/{name}` now serves those documents beside the pictures
  for a cross-device open. Two more ways in — `POST /v1/office/extract` for an
  app or a script (`{"block", "text", "notes", …}`), and an `attachments` array on
  `POST /v1/bots/{profile}/message` for a bot handing a document to another bot — and one way back: a
  bot writes the file in its workspace and links
  `/v1/workspace/<profile>/file?source=workspace&path=…`, which the apps turn into a file chip (the
  route canonicalises both sides, so `..`, absolute paths and symlinks out of the folder are
  refused). No new crate is a C dependency (`lopdf`, `zip` + `quick-xml`), and the image paths are
  untouched.

### Fixed
- **The bubble shows only what you typed** when a file was attached — the text the host extracts for the
  bot is no longer drawn into your message after a reload.
- **Quick Look** compiles: the preview view's initializer is failable and is now bound rather than assumed.

## [0.1.646] — 2026-11-24

### Fixed
- **A reply now appears in the conversation it belongs to, without switching away.** The desktop was showing
  the previous message and the "musing…" indicator while the sidebar already had the new one: a reply that
  arrives while the pane is open could be filed against the wrong session and dropped, and the indicator only
  ever cleared on one specific event. Both are fixed — the pane settles the turn from the host's own answer,
  and it follows the bot's conversation if the host moved it.
- **Group chats show their heading on the desktop**, under Group chats, the same way the bot categories do —
  and fold with them.

### Changed
- **Pet callouts are black with white text.** A frosted material samples whatever is behind it, so over a
  bright wallpaper it was a white panel whatever tint sat on top; the fill is a near-black now, with white
  text, a faint white hairline and the same curved tail and placement.

## [0.1.645] — 2026-11-24

### Changed
- **The bot panel's buttons sit evenly in their corners.** The bell, ＋, Settings, search and the sidebar
  toggle were 12 pt in from the sides but only 4 pt from the top and bottom, so a corner button looked twice
  as far across as it was up. Both chrome rows use one 10 pt margin on every side now, and the rows grew by
  the difference.
- **Settings ▸ About states the host version on one line with its action.** Version and state together, and
  `Check now` is a real button on that same line instead of muted text stranded at the far right; the state
  is toned — normal when current, accent when an update is available, warning when the host cannot be asked.

### Fixed
- **An error from another conversation no longer appears in yours.** Host errors were drawn in whichever
  chat was open, because the event did not say which session it belonged to — which is how "No LLM provider
  configured" appeared over a healthy conversation. An error is now shown only in the conversation it
  belongs to; anything else goes to the log.

## [0.1.644] — 2026-11-24

### Added
- **One word on the island.** The Dynamic Island now says **Working** while a bot is busy, **Needs you**
  when it is blocked on an approval or a question, and **Finished** when the task is done — readable
  without expanding it. The elapsed time moved to the expanded view.
- **The host updates itself, from either app.** When a newer hermeyd is published, the bell lists it with
  its version and an **Update** button (Settings ▸ About on the Mac too). One press downloads it, checks the
  published checksum, swaps the binary and restarts the service, with the host's own stages in the row.
- **Rollback is automatic.** The previous binary stays on disk; if the new one does not stay up, two failed
  starts put it back and the row says so with both versions.

### Fixed
- The Live Activity's coordinator now publishes the phase alongside the step, so the pill cannot show a word
  the card disagrees with.

## [0.1.639] — 2026-11-23

### Fixed
- **The View menu no longer offers tabs.** "Show Tab Bar" and "Show All Tabs" were the system's window-tab
  items; Hermey has no tabs, so both were always dead. They are gone — the text-size commands and Enter Full
  Screen are untouched.
- **Settings ▸ Agents ▸ Bot instructions tells the truth, and Install works.** The row asked the host for the
  skill and got an answer that meant "not found", so it sat on *Unavailable* on a healthy host while the
  button's own result went nowhere. The host now reports what it actually has — installed, out of date, or
  missing per agent — and the button does the work and says what happened; if it cannot act, the row says
  why instead of going quiet.
- **The Live Activity on the Lock Screen has words in it.** It drew a card with no text at all and never
  refreshed during a turn. It now names the bot and what it is doing — thinking, reading, running a tool,
  streaming the reply — updates as the turn moves, and ends with *Done* plus the first line of the answer.

- **The View menu no longer offers tabs.** "Show Tab Bar" and "Show All Tabs" were AppKit's automatic
  window-tabbing items: Hermey has one window per scene and never a tab, so both sat above the
  Bigger/Smaller/Default Text Size entries as items that could not do anything. `NSWindow
  .allowsAutomaticWindowTabbing = false` is now set in the app's own `init` — the only place it is
  honoured, because it has to be decided before the first window exists — and `WindowTabMenu.purge()`
  drops any item of that family that grew in anyway (by AppKit's selector, with the two titles as a
  backstop). The text-size commands and Enter Full Screen are untouched.

- **Settings ▸ Agents ▸ Bot instructions says what the host actually has, and the Install button
  reports what it did.** The row read `GET /v1/local-computers/skill`, and hermeyd answered that path
  with a **404 placeholder** — so `refreshSkill` saw a non-2xx, set `skill = nil`, and the row sat on
  *Unavailable* for ever while the button's own `POST` result was thrown away by `try?`. The GET is a
  real read now (`skills::inspect`): it decides each target directory exactly as `write_skill` would —
  `current`, `stale`, `foreign` (the owner's own skill, left alone), `missing`, `platform-skipped`,
  `unreadable` with its reason — and writes nothing, so the row may ask as often as it likes. The row
  therefore shows Installed / Not installed / Update available / Yours, `Unavailable` only for a host
  that did not answer, and a sentence under the button in every other state: why it is disabled
  ("Pair a host first…", "Installing…"), the host's own `detail` with its status code when a press
  failed, or the directories an install could not write. The `POST` route reuses boot's install and
  emits one `local_computer.skill` audit record. `hermeyd` 0.3.9.

## [0.1.637] — 2026-11-23

### Changed
- **Bigger bar icons.** Every icon in the bot list's top and bottom bars is 25% larger, glyph and click area
  together — the bell, ＋, Settings, update, search and sidebar toggle on the Mac, and the bell, gear and ＋
  on the phone.
- **The waiting list looks like the list it belongs to.** On the phone the sheet now opens at the height its
  rows need instead of a mostly empty panel, its header sits just under the grabber, and each row carries
  the unread badge on the avatar's corner — with the bot's name, time and last line aligned the same way as
  the bot list.

### Fixed
- **No more blue ring around a waiting row on the Mac.** That outline was the system's keyboard-focus ring;
  rows show a hover highlight now and are still usable from the keyboard.

## [0.1.636] — 2026-11-23

### Changed
- **Updates no longer interrupt you at launch.** The app still checks once when it opens, but it no longer
  puts a dialog in front of you when it finds something. Instead a small ↓ button appears on the bot list's
  bottom bar, just left of search: press it and the normal download-and-install window opens. Skip an update
  and the button stays away until the next launch.
- Settings ▸ About ▸ Check for Updates… works exactly as before, and nothing installs without a press.

## [0.1.635] — 2026-11-23

### Added
- **Reactions follow you.** A reaction is kept by the host now, not by the device that made it: react on
  the Mac and the phone shows it, react on the phone and the Mac shows it — live, while the conversation is
  open. Reactions you already had on a device are sent to the host once, so nothing is lost. Unpaired, both
  apps keep working exactly as before, locally.
- **A bell that says what is waiting.** The bot list's top row is now the bell and the ＋ menu. The bell
  lists the bots with unread replies, most first, each with the first line of its last message; pick one and
  it opens with that bot. iOS gets the same bell, right beside Settings.

### Changed
- **The bot list has a floor bar.** Settings moved to the bottom left; search and the sidebar toggle to the
  bottom right. The list fades into both ends of the panel over the same 26 pt, so no edge cuts a row.
- **An empty composer says who you are writing to** — "Message Cody", the same words the phone shows.

### Fixed
- Two compile-time faults the app build caught before release: the reaction table was cleared with an array
  literal where Swift needs a dictionary one, and the reaction key took the row id at the wrong width.

## [0.1.633] — 2026-11-23

### Added
- **The pet tells you when a bot answers while you are away.** If Hermey's window is minimised (or the app
  hidden) and a bot you asked something replies, that bot's pet hops once and wears a small badge with the
  count. Click the pet and the balloon opens with the reply; the badge clears with it — and the dot in the
  app's bot list clears at the same time, because both read the same count.
- It stays quiet when you are already looking at the window, and it does not hop for a reply its own
  balloon is showing.

## [0.1.632] — 2026-11-23

### Fixed
- **No more eyes drawn over the faces that already have them.** The pet's own icon carries its eyes — the
  cloud's two vertical bars — and an overlay of horizontal eyelid shapes crossed them into a doubled,
  T-shaped face. Nothing is painted on the art now.
- **The blink is the body.** A deeper squash (0.74) of the whole icon, which is what a cartoon face does
  when it blinks.
- **Looking around is the icon drifting.** A few points left and right every two to five seconds, carried by
  the picture itself. Reduce Motion still stops the drift.

## [0.1.631] — 2026-11-23

### Changed
- **The pet's balloon keeps the conversation.** Closing it no longer throws the last question and answer
  away: reopen and it is still there, selectable and copyable. A **New** button sits beside **Copy** — only
  when there is something to clear — and starts a fresh ask.
- **It no longer covers the pet.** The bubble seats above-right of the icon, falls back to above-left and
  then above, and never overlaps the pet; the tail root lands on the pet's edge rather than the bubble's
  middle.
- **Eyes.** The face gets pupils that drift left and right every few seconds and a blink whose eyelid band
  closes over the shipped eye bars — on its own cycle and when you click the pet. Reduce Motion stops the
  drift and gentles the rest.
- **Dragging tracks the cursor.** The window follows each mouse-drag event directly instead of animating,
  so it no longer lags behind the pointer.
- **Much more see-through.** The callout is now 70% transparent — a thin material with white at 0.16 over
  it — with a faint text shadow so the ink still reads on a busy wallpaper.

## [0.1.630] — 2026-11-23

### Changed
- **The balloon is glass now.** It was an opaque near-white sheet; it is a frosted callout — a material with
  white at 0.38 and a thin inner rim — so a dark wallpaper tints it grey-blue and a bright one cream, while
  the ink stays readable.
- **A real callout shape.** Corners are 26 pt and the tail is a curved 26×13 shape with a rounded tip instead
  of a straight triangle, still pointing at the pet wherever the bubble ends up.

### Fixed
- **The answer is visible again.** It was being drawn into zero height — the reply arrived, Copy could hand
  it over, but nothing appeared in the bubble: a `ScrollView` measures as nothing inside a panel sized to fit
  its content. It is a self-sizing text now.

### Added
- **Long answers grow, then scroll.** The bubble expands with the reply up to 240 pt and scrolls past that,
  so a two-line answer makes a small bubble and a long one stays readable instead of stretching off the screen.

## [0.1.628] — 2026-11-23

### Fixed
- **The pet's balloon gets its answer.** Four faults stacked in the host's ask path: it waited for the
  wrong side of the conversation (your message rather than the bot's reply), polled the engine's runtime
  session id instead of the stored one, opened the retired engine home where no profile database lives,
  and anchored its search on a timestamp taken *after* the question was delivered. All four are fixed, so
  a question typed into a balloon now comes back as the answer instead of sitting on "thinking" while the
  reply appears only in the app.
- The pet also stops slurring its own fix: the guard tests now allow the ask-path change that ships with it.

### Changed
- **The balloon is a callout, not a box.** Near-white at 0.82 over a material in both app themes, with a
  tail that follows the pet even when the bubble has to be nudged back onto the screen.
- **Pets float.** The icon casts its own soft shadow inside the transparent window.
- **Pets blink.** A quick squash of the body on a random 3–9 second timer, and clicking a pet adds a hop
  and a double blink as the balloon opens. Reduce Motion keeps the hop off and gentles the rest.

## [0.1.627] — 2026-11-23

### Fixed
- **The pet can ask.** Every question came back as "not found": the host's `ask` route only accepted calls
  from its own machine, and both apps reach it through the tailnet proxy. It now accepts a call that carries
  your device's ticket — and still answers an unauthenticated proxy exactly as it answers an unknown route.
- **The balloon blends.** It was an opaque sheet sitting on whatever desktop it happened to open over; it is
  now a translucent material with the theme colour over it, so the wallpaper and windows show through and the
  text stays readable.

## [0.1.626] — 2026-11-23

### Added
- **Desktop pets.** Each bot can put itself on your desktop: in that bot's settings, turn on *Show on the
  desktop* and its own picture appears — no frame, no window background, just the icon on your wallpaper.
  It bobs, tilts and occasionally hops; drag it anywhere and it remembers where you left it, per screen.
- **Ask it something.** Click the pet and a balloon opens with a field. Type, press Return, and the balloon
  shows it is thinking, then the answer — scrollable, with Copy. Escape or a click away dismisses it.
- **Right-click → Close pet** takes it off the desktop and switches the setting off, so it is the same one
  switch that brings it back.
- Clicks on the transparent part of a pet reach whatever is underneath: the pet occupies its icon, not a
  rectangle of your screen.
- Reduce Motion is respected — no hops, and a much gentler bob.

## [0.1.625] — 2026-11-23

### Added
- **⌘K opens this bot's soul.** The command palette has "Edit this bot's soul": one verb, one sheet, for
  the bot on screen — no detour through settings to find the tab. Saving writes to the host, and the editor
  still says the thing that matters: a conversation already open keeps the soul it started with until it is
  reset.

## [0.1.624] — 2026-11-23

### Fixed
- **The Mac's conversation pane stops fighting the reader.** Two faults in the code that holds your
  place while older messages load:
  - the position was armed whenever the transcript merely *grew and its first row changed* — which is
    what a resume looks like — so the pane scrolled although nothing had been inserted above you. The
    guess is gone; only a real "load earlier" arms it now.
  - one page could move the pane several times, because the lazy list re-measures itself as it lays
    out and every re-measure applied the correction again. A prepend now corrects once.
- **If it still moves, the log says why.** New `paging · anchor …` lines record when the hold was armed
  (and from which signal), corrected by how much, released, or — the important one — that a size change
  happened with no hold at all.

iPhone was never affected: it has no such hold, which is exactly why it felt smooth.

## [0.1.623] — 2026-11-23

### Changed
- **A mail draft card is editable the moment it arrives.** No Edit step: `To`, `Cc`, `Subject` and the body
  are fields straight away, and the card carries exactly two buttons — **Send** and **Discard**.
- **Send posts what you typed.** The turn carries the edited headers and body, so the bot acts on your
  version rather than the file's original. `Cc` is omitted when you leave it empty.
- **Discard is local.** It dims the card and sends nothing; the bot's own card file is never touched.
- **Your typing is not overwritten.** Edits live in the card's own state and are only reseeded when the
  document itself changes, so a redraw cannot eat what you are writing.
- A resolved draft stays a receipt (which action was taken, no fields, no buttons), and a draft with no
  `email` block renders exactly as before.

## [0.1.622] — 2026-11-23

### Added
- **Every card kind draws now, not just approvals.** A bot's mail draft arrives as `draft-email` and used
  to fall back to plain text, because only `approval` had a layout. Drafts now show the subject as the
  heading, `To` and `Cc`, and a scrollable preview of the body; `task` cards show a status chip
  (pending, running, done, error, awaiting approval — `status.label` wins when the card sets it) above
  the body and its actions. All three kinds share the same `body[]` blocks: plain text, key/value rows
  and labelled fields, with an empty body drawing nothing.
- **A resolved card says what was chosen.** Once `resolved` is set, the chosen action keeps its tick, a
  "Resolved: …" line names it, and every other button is disabled.

### Fixed
- **A photo from the camera roll attaches.** The host's image route refuses extensions outside its own
  list (png, jpg, jpeg, gif, webp, bmp), and an iPhone shoots HEIC — so picking a photo failed after the
  preview with "unsupported image extension: .heic". HEIC and HEIF are now decoded and re-encoded as
  JPEG at quality 0.85 before upload, ahead of the 8 MB check so the limit applies to what actually
  travels. Anything undecodable passes through untouched, so the host's own reason is what you see.

### Changed
- **Card reads are keyed to their message.** The read now carries the message id as well as the session,
  so two messages that name the same card keep their own snapshot instead of sharing one row.

## [0.1.621] — 2026-11-23

### Added
- **Agent cards draw natively, on both apps.** A reply that carries a `::card{id="…" kind="…" file="…"}`
  line now draws the card instead of describing it: an approval layout with up to three actions, where a tap
  sends that action as an ordinary turn. The marker line is taken out of the prose, marker examples inside
  fenced code blocks are left alone, and a card that cannot be read says "Card not available" with the
  reply's text still shown. Cards sit after A2UI markers and before genui blocks, and `cards.enabled`
  turns the whole thing off so the marker stays plain text.

### Fixed
- **A reply with CRLF line endings no longer hides its card markers.** Swift treats `"\r\n"` as a single
  character, so splitting on `"\n"` never broke such a message: every marker stayed buried inside one
  enormous line and the prose lost its carriage returns.

### Changed
- **One engine home.** `hermeyd` now resolves the Hermes home that actually holds `profiles/` — `~/.hermes`
  first — instead of adopting the first directory that exists and silently serving a second fleet.
- **Docs, site and README say what the code does.** The bridge era, the removed share extension and scripts
  that never existed are gone; Live Activity, gallery paging, group-chat rename, the macOS build flag and the
  two-number version policy are documented; two routes that were documented as stubs are described as the
  implemented routes they are.

## [0.1.620] — 2026-11-22

### Changed
- **No share-sheet entry.** It cannot work on a sideloaded install: a third-party signing certificate can carry
  an app-group entitlement but cannot provision the group id the extension needs, so the sheet could only ever say
  "no shared storage yet". The extension, the entitlement and the wiring are removed.

### Fixed
- **The expanded Live Activity is no longer an empty black bar.** The expanded island's minimum height is 84 pt,
  which fits one row; asking for a second row while a turn runs collapsed the lower region and left the pill with
  nothing but the bot's name. The bottom row now appears only when the turn has finished — status and a clipped
  line of the reply — so a running turn is name plus timer, and a finished one is name, elapsed and what was said.

## [0.1.619] — 2026-11-22

### Fixed
- **The Mac conversation no longer slides while you read history.** Loading older messages inserts rows above the
  viewport, and the Mac transcript did nothing about it, so everything under the pointer moved down by the height of
  the page. It now holds the clip view's origin across the merge — no animation, released the moment you drag or jump
  to the bottom.
- **The Dynamic Island fits.** The pill spanned two-thirds of the screen and covered the clock: a `.timer` text fills
  the width it is offered, and a compact slot offers all of it. Every compact slot is now size-pinned, the bot's name
  is shortened in code, and a finished turn shows a clipped line of what the bot actually said.
- **The share sheet carries plain files.** A file from Files was refused as "too large" without its size ever being
  read, because the size probe ran before the security scope was opened. Files are carried now, and a refusal names
  the file and the reason.
- **The share sheet says which problem it has.** "Open Hermey once" no longer stands in for "this build has no app
  group" — no shared storage, no bot list yet, and a stale list are three distinct messages, with a Reload button.
- **A reply named by a session the app cannot place re-reads the chat** instead of vanishing until you switch away and
  back.
- **Gallery** closes with a downward swipe on iOS, without disturbing the page swipe or pinch.

## [0.1.618] — 2026-11-22

### Added
- **Share sheet.** Share text, links and images from any app on the phone straight into a bot: pick the bot in
  the share sheet, and it arrives as a message with the files attached, the same way a chosen photo does.
- **Dynamic Island and lock-screen card.** While a bot works on your message an activity shows Hermey, the bot's
  name and a running timer; it closes when the reply lands, and a launch sweeps anything orphaned by a crash.
- **Gallery in the image viewer.** A message with several images opens at the one you tapped and pages through the
  rest — swipe on the phone, arrow keys and chevrons on the Mac — with a "2 of 5" counter.

### Fixed
- **The conversation no longer shifts while you scroll.** Since the host service move, every session attach minted a
  fresh *runtime* id, and the app treated each one as "a session moved": returning to a chat resumed it, replaced its
  rows and moved the content under your hands. Announced ids are translated through the runtime→stored alias before
  being compared.

## [0.1.617] — 2026-11-22

### Fixed
- **A genui card no longer swallows the Mac's scroll wheel.** Scrolling the conversation stopped dead while
  the pointer sat over a card and only resumed once the cursor left it: the card's web view handles scroll
  events itself on macOS, and the phone never had the problem because its inner scroller is switched off.
  The Mac card now hands the wheel to the transcript, which is where it belongs.

## [0.1.616] — 2026-11-22

### Fixed
- **Every A2UI surface in a reply is drawn, not just the first.** A reply carrying several surfaces showed the first
  card and silently dropped the rest, because the text fallback strips every marker — so the surfaces after the first
  had nothing left to render. Both transcript views now place them in order.

## [0.1.615] — 2026-11-22

### Added
- **Agent-driven UI draws in the transcript, on both clients.** A reply that carries an A2UI surface is rendered as
  the surface instead of its raw JSON, with a runtime switch to fall back to text if anything looks wrong.

### Fixed
- **Returning to a chat no longer reloads a conversation the cache already holds.** A captured thread carries the host
  stamp its rows were read at but none of its own, so the sweep read "the host has written since" and forced a resume —
  the "it preloads, then loads again" case, in its real order. The guard now compares the line the host names against
  what the thread actually holds.
- **The Mac build validates the A2UI build plugin non-interactively.** The package ships an SPM build-tool plugin, and
  without `-skipPackagePluginValidation` the macOS build stopped before compiling anything.

## [0.1.614] — 2026-11-22

### Fixed
- **The prefetch and resume fixes are actually in this build.** 0.1.613 was published from `main` while the work sat
  on a side branch, so its release notes promised warming and returning-to-chat fixes it did not contain. This build
  has them: launch warms every bot by resuming its stored conversation and releasing the runtime session it minted,
  and returning to a chat resumes when the host may know more than the cache — "resuming: the host's newest message
  is not known yet" — instead of showing a cache it cannot prove is current.

- **The launch sweep actually pre-warms the chats.** The sweep read every bot's transcript with
  `session.history`, and that call resolves **only sessions the host is already holding live**
  (`_sess_nowait` is a plain `_sessions.get(sid)`; its `4001` says "client should resume the stored
  session"). A `profile` did not help — measured on the live host, a stored id is refused with one
  and without one — so the sweep failed for every bot, eighteen times a launch, and nothing was ever
  warm. Warming is a **resume** now: `session.resume {profile, session_id}` answers in 0.03–0.7 s and
  carries the `messages` itself, one call per bot, walked one bot at a time. A resume registers a live
  session on the host attached to this connection, and such a session is never reaped or LRU-evicted,
  so each one the sweep minted is closed again by the **runtime** id the resume answered with — while
  a session the host was already holding (another window, another device) is left alone, and a turn
  in flight is never closed. The sweep also resolves the conversation from the host *before* resuming
  it, and treats `session not found` as what it is — a stale id, because the host re-minted that
  bot's conversation — by dropping the remembered id and asking once more. What it reports is two
  lines at most: `cache prefetched 17 of 18 conversation(s) at launch (resume 0.1s avg)`, and one
  warning naming the few that failed with their reason
  (`Sources/HermesKit/GatewayClient.swift`, `Sources/HermesKit/GatewayClientActor.swift`,
  `Sources/HermesAppKit/AppModel.swift`).

- **A reply that arrives while you are away is in the thread when you come back.** Returning to a
  conversation inside the cache window kept the cached rows and skipped the resume whenever the
  host's newest-message stamp had not reached the device yet — `nil` compared as "nothing new" — so
  a message the badge already knew about stayed invisible until something else forced a re-read. The
  cache is now kept only when the host is *proven* quiet: its newest stamp is known and no newer than
  the snapshot's, the bot has no unread activity, and the socket named no other session for it.
  Otherwise the snapshot still paints first and the resume runs. A skipped resume says why
  (`no resume: the cache already holds the host's newest message`), and so does one the cache made
  necessary (`resuming: the host's newest message is newer than the snapshot`).

## [0.1.613] — 2026-11-22

### Fixed
- **Prewarm works again.** At launch the app fetched every bot's transcript through `session.history`, which the host
  only answers for a conversation already attached in memory — so all 18 bots failed with "session not found" and the
  list stayed cold until each chat was opened. Warming now resumes each bot's stored conversation, keeps the messages
  and releases the runtime session it minted, so a launch warms the whole roster without leaving agents behind.
- **A reply that arrives while you are in another chat now shows up when you return.** The cache painted first and then
  skipped the resume, on the strength of a timestamp that is simply unknown before the first sweep — unknown was read as
  "nothing new". Returning now resumes whenever the host may know more than the cache does, and says why: "resuming:
  the host's newest message is not known yet".

## [0.1.612] — 2026-11-22

### Fixed
- **The log sheet has visible copy and share controls.** They existed but lived in a toolbar, and macOS's
  sheet presentation drew only Close and Refresh there, so the sheet showed no copy at all. Copy and Share are
  now in the sheet body beside the entry count: *Copy shown*, *Copy all* (including lines a paused tail is
  holding back) and *Share log*, each with a receipt that says how much was copied — "Copied 214 lines shown".

- **View log can be copied, counted and sent.** The Mac sheet's Copy, Share and Clear buttons were
  `ToolbarItem`s, and the system's sheet chrome dropped them: the owner was looking at a sheet whose
  only buttons were *Close* and *Refresh* while the copy code sat in the file. Copy, share and clear
  are now controls in the sheet's own body, under the filter row, as *Copy shown*, *Copy all*,
  *Share log* and *Clear* — one row on the phone and on the Mac. *Copy all* reads the log itself
  rather than the feed, so the lines a paused tail is holding back go with it; the entry count is
  replaced for 1.6 seconds by what actually happened (*Copied 214 lines shown*), and never by a bare
  *Copied* when nothing was written. Log rows are selectable, and *Share log* hands the same text to
  the system share sheet so the phone can send it to Messages or Mail
  (`Sources/HermeyUI/ClientLogView.swift`).

- **The service stops reading a dashboard flag as a statement about its own socket.** `hermeyd` asked
  `/api/health` whether the engine wanted a token and read `auth_required: false` as "none needed".
  That flag describes the dashboard's OAuth gate: a loopback `hermes serve` answers `false` while its
  `/api/ws` still demands the per-boot session token and refuses a tokenless upgrade with `403`. Every
  relay, RPC and display socket therefore failed with `403 Forbidden` against a stock v0.23.0 engine.
  The probe now asks the socket itself — one tokenless upgrade, accepted → send nothing, `401`/`403` →
  send the token, anything else → send it as before — and boot and `status` both name the evidence
  instead of quoting the flag.

## [0.1.611] — 2026-11-21

### Added
- **Arrange bot categories on the phone.** Long-press a group heading, or use the new ⋯ menu at its trailing
  edge; the verbs grey out at the ends. The host stores the whole arrangement, so the order is the same on
  every device.

### Fixed
- **A refused category move no longer looks like a successful one.** The Mac's menu called the move through
  `try?`, so a write the host refused simply appeared not to happen. It now says "Category not changed".
- **The vision model row shows the configured model instead of "auto".** Hermey read the flat
  `auxiliary.vision_provider` key while the engine and both shipped configs use the nested
  `auxiliary.vision.provider`, so the setting always looked unset.

## [0.1.610] — 2026-11-21

### Added
- **Full screen in the shared computer, on both platforms.** The pane's ⤢ hands the Mac's *window* to full
  screen and drops the header, status bar and safe-area inset on the phone. Either platform keeps one floating
  bar — take-over / hand back, zoom −/+, the level, Fit, exit — and the picture zooms 1×–5× and pans, clamped to
  its edges, with take-over clicks landing on the right framebuffer pixel at any zoom. `Esc` exits.

### Fixed
- **The full-screen button actually moves the window.** Turning full screen on toggled the window without
  adopting `.fullScreenPrimary`, which macOS accepts and then ignores: the pane grew, the menu bar, dock and
  traffic lights stayed, and nothing said why. The behaviour is adopted first, and the request and any refusal
  are logged with the window's style mask.
- **Looking a conversation up no longer changes the selected bot.** `endlessSession(for:)` selected the bot as a
  side effect, so background readers could move the user's screen — reported as the selection jumping between
  bots mid-conversation. A lookup now returns before anything is selected.
- **Release notes reach the update dialog.** The publisher read `--notes` at six call sites and the release
  script always passed a non-empty placeholder, so the changelog could never be used. One resolution now feeds
  the release body, both manifests and the Sparkle feed's description, clipped to 4000 characters.

## [0.1.607] — 2026-11-20

### Added
- **The shared computer goes full screen, and can be zoomed and panned while it is there.** The pane's
  own arrows now hand the *window* to full screen on the Mac (the green button's behaviour, with the
  pane falling back into its panel if you leave full screen that way, and `Esc` as the third way out)
  and drop the header, status bar and safe-area inset on the phone; either platform keeps one floating
  bar carrying take-over / hand back, zoom −/+, the level, Fit and the exit. The picture zooms 1×–5×
  and pans — trackpad pinch about the pointer, two-finger scroll or ⌥-drag on the Mac, pinch and
  two-finger drag on the phone — with the pan clamped to the picture's own edges and take-over clicks
  still landing on the exact framebuffer pixel at any zoom (the page's CSS transform is divided back
  out by the patched `clientToElement()`, guarded by `Tools/verify/novnc_zoom_pan.mjs`).

## [0.1.606] — 2026-11-20

### Fixed
- **A bot's window follows its conversation when the session id moves.** The host mints a runtime
  session id per attach and a new one when a conversation starts, while the app stores the durable
  id — so an event could name the conversation on screen by a name that window had never seen. Every
  branch of `apply(_:)` returned early on that mismatch: the sidebar updated its preview and raised
  the unread badge (the message *had* arrived) and the open transcript refused to draw it, which is
  the reported "cody has an unread of 1 and cody's window does not show it". A content event for the
  bot on screen now follows the conversation — one `session.resume`, then paint — while a session
  this launch has attributed to another bot is still only counted (`Sources/HermesAppKit/AppModel.swift`).

- **A badge the open conversation cannot clear is gone.** When the transcript on screen is current
  for a bot, that bot's dot and count are dropped and its read mark moves to the host's own newest
  stamp, so a reply that is *visible* can no longer leave a number behind it.

- **Only navigation moves the screen.** `endlessSession(for:)` resolves *and selects*; a background
  reader using it is what made the last caller win. `conversationID(for:)` is the pure lookup (pin,
  then the host's canonical Bot Chat, then the remembered id) that touches no published state and
  sends no resume, and every selection `endlessSession` does make is now logged.

## [0.1.604] — 2026-11-20

### Fixed
- **A bot's window can no longer show another bot's messages.** The model holds one transcript for
  whichever bot is on screen, and opening a bot awaited `session.resume` before writing it with no
  record of which open was being written — so switching bots while that resume was in flight landed
  its rows in the window of the bot the user had moved to, sometimes corrected by the next event and
  sometimes stuck until a relaunch. The open now captures `botEpoch` before its first await and
  discards an answer that arrives after a switch, and the transcript carries `transcriptOwner` so any
  write of rows states whose they are and is refused when the answer disagrees — a guard in the
  model, because no view can tell which bot it was handed (`OpenGenerationTests`).

- **A chat that stops answering now says which side went quiet.** Nothing recorded how long the wire
  had been silent, so "it gets stuck sometimes" could not be told apart from a host that had simply
  stopped talking. `AppModel` keeps the last socket event and, on the sweep's clock, logs one line
  when a turn has run 45 s with no frame at all. A transcript replacement whose first row changes —
  the scroll jump — records the row it replaced, so that report has an anchor too.

## [0.1.603] — 2026-11-20

### Fixed
- **A cold start opens the conversation instead of a banner.** The first `session.resume` after a
  launch could meet a socket that was still coming up (or one a previous turn left dead), and the app
  reported that transport failure as *"could not open the conversation: … Software caused connection
  abort"* — with nothing retrying, so the only cure was to leave the bot and come back. A resume that
  failed on the transport now dials once, ahead of the reconnect backoff, and asks again; a resume the
  host *refused* (`4001`/`4007`) is untouched, because replacing a forgotten id is the one case where
  the retry would be a lie (`TransportFailure`, `TransportFailureTests`).

- **The keyboard opens on the first tap after a cold launch.** The composer is disabled until a
  resume lands, and a disabled field never becomes first responder — so the tap that a user makes
  while a bot is opening was recorded nowhere and the keyboard only appeared on a second tap, seconds
  later. The composer now remembers a tap that arrives while it is disabled and takes the caret on the
  update that enables it; the phone's conversation owns that `@FocusState` itself, so the tap it
  catches while opening is honoured the moment the session is interactive. A third path — a tap on the
  card's own padding — goes through the same request instead of being swallowed.

- **A message no longer arrives seconds after the notification for it.** The banner and the message
  travel different paths: the sweep that finds a reply is an HTTP read, the transcript needs the
  WebSocket, and a socket in backoff sleeps up to 30 s between attempts with nothing able to shorten
  the pause. `GatewayClient.retryNow()` ends that pause and dials immediately (re-arming the ladder if
  the forced attempt fails), and the app calls it from the notification path, from returning to the
  foreground, and from a resume that died with the socket.

- **A bullet, quote or heading containing a pipe is text again, not an empty table.** Allowing a
  blank header row (so `| | |` above `|---|---|` renders as GFM's blank-headed table) matched the
  header on cell *count*, so `# a | b` above `--- | ---` became a two-column table with no headings
  and the line itself disappeared. Only a row made entirely of pipes and spaces may stand in for a
  header (`MarkdownTableParser.isBlankRowLine`), which is the shape the empty-header case actually is.

## [0.1.594] — 2026-11-20

### Added
- **A bot logs in without ever seeing the password.** The bot asks for a *card* — which sign-in method
  (choice), a username/password or a one-time code typed by the owner (secret), or permission to use a
  saved connection (confirm) — and the value travels app → bridge → the page, never into the
  transcript, the model's context or a log. Every route answers by site and kind and never by value, a
  card is single use, in memory only and dead after two minutes
  (`Bridge/hermes_bridge/credentials.py`, the promise is `docs/CREDENTIALS.md`). The fill lands in the
  bot screen's own Chromium through its DevTools port — a stale `DevToolsActivePort` is refused rather
  than trusted, and values go in through the native setter so a React form does not keep believing the
  field is empty — or through the **Hermey Sign-in** extension, which holds a loopback socket to the
  bridge and can therefore fill a browser the owner started themselves (`browser-extension/` holds the
  extension's source; stable Chrome 137+ accepts `--load-extension` and loads nothing, so the browser
  has to be Chrome for Testing or Chromium). Both apps draw the three
  cards, and both get the Composio connection screen — six account lookups run together instead of one
  after another, 2.41 s → 0.82 s measured on the host, and a failure shows the underlying error
  instead of one generic sentence.

## [0.1.577] — 2026-11-19

### Changed
- **CI now scans the repository's history, not just the working tree.** `secret_scan.sh` cannot see a
  credential that was committed and later removed, and this repository is public, so its history is
  published too. The hygiene job checks out full history and runs `Tools/ci/secret_scan_history.py`,
  which walks every reachable blob once and prints a masked prefix, length and fingerprint rather than
  the value — a log that reported the finding must not become the leak.

## [0.1.573] — 2026-11-18

### Added
- **Settings → Computer shows whether the agents can reach this Mac.** One row: *Installed*,
  *Update available*, *Not installed*, *Yours* or *Unavailable*, with the skill version, a button that
  re-runs the host's installer, and a red line when the command the skill points agents at is missing
  from the host. *Yours* means the owner wrote a skill by that name, so the host leaves it alone;
  *Unavailable* means the host did not answer, which is deliberately not the same claim as *Not
  installed*. It reads a new read-only `GET /v1/local-computers/skill`; installing stays on `POST`, so
  looking at the row can never write to the host.

- **Every bot knows how to reach the owner's Mac, without being told.** The local-computer executor
  was only useful to a bot that already knew the CLI existed — the rest tried SSH and failed. The
  bridge now ships a `mac-local-computer` skill inside the package, writes the CLI to
  `<state>/bin/local_computer.py` where it survives the installer deleting its checkout, and renders
  the skill with that real path and this bridge's URL on every start. It lands in the shared skills
  dir when Hermes has one (one copy, every bot, including bots created later) and otherwise in the
  install home plus every `profiles/*/skills`. A file of the same name without the
  `managed_by: hermey-bridge` marker is the owner's and is never overwritten;
  `POST /v1/local-computers/skill` re-installs on demand. The skill is written as the playbook a bot
  needs, not a man page: check the Mac is connected first, argv-not-shell, `observe` before any
  `click`, the 30-second observation rule, the single global GUI gate, and a failure table that maps
  every bridge error to what to do about it. `ReadWritePaths` in `setup/install.sh` grows to include
  the skills dirs, because a sandboxed bridge cannot write a skill it is not allowed to write. The
  file is only rewritten when its content actually differs from the template (an identical one is
  untouched), and a bot that hand-edited it keeps its words: the superseded text is left beside it as
  `SKILL.md.previous` rather than being silently replaced on the next start.

## [0.1.515] — 2026-11-16

### Added
- **A busy bot face performs now.** Between the acting it already had, every busy state — working,
  thinking, reading, writing, using the computer — jumps and flips: a crouch and a leap with a
  squash-and-stretch landing, then next beat a full 360° roll or an out-and-back 180° twist,
  alternating direction, one stunt every ~2.6–3 s. The body is punctuation and the eyes are the
  acting: saccades on their own faster clock (a glance every ~0.9 s, a two-step double take every
  fifth), each dart a 60 ms move and a hold, and a squint on a slower one still. Idle keeps its
  float, waiting holds its look at you, and error rests: a backflip there would be a lie. Stunts are
  a pure function of the clock and the bot's own phase — two faces never jump in lockstep, a
  backgrounded window stops them, Reduce Motion and the Appearance switch still stop everything, and
  the leap is capped in points (2.6 pt at 16 pt, 4.8 pt at 96 pt) so a face in a row never draws
  over the text beside it. No new layers, paths or effects: the same 30 Hz timeline, ~20 more numbers
  per frame (`BotAvatarPerformance`, tests in `BotAvatarPerformanceTests`).

### Fixed
- **A reply the list and the notification announced is in the chat when it is opened.** The row, the
  dot and the banner come from the sweep that reads every bot's newest message from the host; the
  chat comes from a resume — and opening a bot you had left within the last two minutes skipped that
  resume entirely, on the assumption that anything new would arrive on the live socket. It doesn't: a
  reply for a bot that is not on screen is dropped by the model, not buffered, so the chat opened on
  the strength of its own banner showed the moment before the reply and asked the host nothing. The
  cache now yields when the socket has named a session that is not on screen, or when the host's
  newest message for that bot is newer than the one the snapshot contains — both host-clock facts, so
  a device with a fast clock cannot pin itself to its cache. An idle *open* conversation is also
  re-read when a sweep sees the host has written, which covers the messages that produce no socket
  event at all: another device's turn, an agent posting outside a run, a bot-to-bot transfer. Nothing
  new still comes from the cache, instantly (`StaleConversationTests`).

## [0.1.477] — 2026-11-16

### Changed
- **The bot list and the Mac sidebar no longer have a loading state of their own.** "Loading bots…",
  "Looking for bots…", "FINDING BOTS / Asking the host which bots it serves…" and their spinners are
  gone: the launch screen covers the pre-roster window instead, and a spinner behind a splash was a
  placeholder for a placeholder. What remains is what can still be true once the gate opens — a failed
  host, a host that is not connected (with its own Connect button), or a host that answered with no
  bots. Nothing in either shell renders a pre-roster placeholder in the launch path.

### Added
- **A launch screen, and one honest answer to "is the app usable yet?".** Both shells now open
  onto a still `BootScreen` — the active theme's canvas with the house face in the middle, 108 pt,
  no motion at all — and `LaunchReadiness` (in `HermesKit`) is the only thing that decides when it
  goes away: gateway connected, roster answered, the selected bot's sessions answered. A host that
  never answers leaves through its **12 s deadline** into the app's own connect/pair UI instead of
  holding someone on an animation; a failed socket and an unpaired install hand off at once. The
  gate is `LaunchGateView` (in `HermesAppKit`), wired in both `WindowGroup`s, and the fade out is
  the reference's own 180 ms. The static launch screen iOS paints before our code runs is pinned to
  Midnight's canvas (`UILaunchScreen` → `LaunchBackground`), so there is no white frame first — iOS
  cannot animate that surface, and it cannot follow a runtime theme either.

## [0.1.473] — 2026-11-16

### Changed
- **One face for a bot, drawn the way the reference draws it.** The eight shipped bodies, the eleven
  palette colours and the reference's hash replace the sixteen hand-drawn silhouettes and twelve
  swatches: every surface that draws a face — the bot list, the chat header, the transcript's
  working row, the drawer, the bot panel, the pair sheet, group chats and the banner icon — now uses
  one `BotAvatarView`, and the old `BotFace` / `BotIcon` / `BotSilhouette` / `BotFaceSpinner` types
  are gone. What a bot is *doing* is no longer guessed per view: `BotActivityTracker` reduces the
  gateway's own tool and reasoning events to one of the reference's eight activities per bot, so a
  row you are not reading still says `reading` or `computer` while that bot works.

- **The icon override is the reference's own value, `#RRGGBB::shape_N`.** The picker offers the
  eight bodies and the palette, previews the choice live, and stores one string in the same field;
  a face chosen by the previous build migrates rather than vanishing.

- **Compaction is the host's job, at its own `compression.threshold`.** Hermes already compacts at
  the start of a turn when the context nears the model's window, so the app no longer second-guesses
  it: the client-side auto-compact trigger and the `hermes.autoCompactTokens` threshold — and the
  field in both Settings screens — are removed. "Compact now" stays the one path the app owns.

- **⌘F toggles the in-conversation search bar.** It used to only open it, so a second press did
  nothing; the same key now closes it, clears the field and hands the scroll position back. A search
  opened from a bot-list finding still arrives pre-filled and is never a toggle.

## [0.1.467] — 2026-11-16

### Changed
- **No borrowed names anywhere in the source.** The design-system module is `HermeyUI` (was a
  third-party app's name), its controls are `HermeyButton` / `HermeyIconButton` /
  `HermeyModelLabel` / `HermeyChatText`, and the two house palettes are **Midnight** (default) and
  **Graphite**. A stored theme id from before the rename resolves forward through
  `ThemeCatalog.supersededIDs`, so nobody is silently repainted; the palette is unchanged.

### Fixed
- **The Mac window is edge to edge at the top, the way Midnight is.** `.hiddenTitleBar` removed the
  title bar but not the inset that stood where it was, so both panes began ~32 pt down and the
  transcript was clipped against that line — the strip read as a title bar and the first visible
  line was sliced through its glyphs. The panes now start at the window's own top edge, the pill sits
  on the traffic lights' line as it was always meant to, and the transcript dissolves under it
  instead of stopping dead.

## [0.1.442] — 2026-11-15

### Added
- **A bot's conversation is now the host's own Bot Chat, so the phone, the Mac and the official app
  read and write the same thread.** Hermey used to keep its own idea of "this bot's conversation" —
  one id in the bridge's `bot_sessions` row plus a per-device cache — which made the two Hermey
  devices agree with each other and with nothing else: a routine's report, another bot's DM, or
  anything typed in Desktop, the TUI or `hermes -p <bot> chat -c "Bot Chat"` landed in a conversation
  Hermey never showed. Hermes already has that conversation: the session titled exactly `Bot Chat`,
  created hidden, resolved by name on every open. Hermey now opens **that** session.
  - On open it asks the host (`profiles.list` → `canonical_session`) and resumes the live
    compression tip rather than the registry row, so rotation compaction cannot leave the app
    following a conversation that stopped moving.
  - A bot with no Bot Chat but with an existing Hermey conversation **adopts** it: the conversation
    is opened and named `Bot Chat`, so history already on the device becomes the shared chat instead
    of being stranded behind a fresh empty one. Only a bot with nothing anywhere gets a new one,
    minted exactly as Desktop mints it (`title`, `hidden`, `follow_profile_config`).
  - Two failures that mean "the canonical chat exists already" are handled silently: a title
    conflict re-reads the host and opens the row that holds the name (never a second chat beside it),
    and a host too old to accept a titled create falls back to a plain one. Every identity read fails
    open — a host that cannot be asked leaves the device on its cached conversation, and nothing
    about that leg is shown as an error.
  - "Reset conversation" now retires the Bot Chat the way Desktop does (`session.archive`, keeping
    the history) and the next open mints its successor, so reset means a new shared chat rather than
    a private one.

## [0.1.346] — 2026-11-14

### Added
- **The bot faces have light and motion** (#100, tiers one and two): a highlight from above, a
  shade below and an inner rim inside the silhouette, then a slow breath, a blink every few seconds
  and a squint while working. Reduce Motion turns the motion off, and faces under 18 pt keep still.

- **A new app icon in the same family**: the melted-corner face, lit, on the app's dark plate, drawn
  by `Tools/release/make_app_icon.py` from the same geometry as the roster.

## [0.1.343] — 2026-11-14

### Added
- **Model has its own row in the bot's panel on the Mac**, with the catalogue out of Bot settings:
  dozens of providers sat between the description and the delete verb.

### Fixed
- **The computer takes the bot panel's place on the trailing edge** — the pane whose row opens it.
  It used to add a third pane with the window grown to fit it, then briefly took the sidebar's slot.

- **Escape only answers in its own window.** With Settings or a sheet in front, Escape closed the
  sidebar behind it; the bot panel's own Escape still closes the panel, and a text field keeps the key.

- **The Settings window closes with Escape and with a click outside**, like every other surface.

- **The bot list sits 16 pt clear of the top edge** (6 was not enough: the selected first row still
  dissolved into the fade).

## [0.1.339] — 2026-11-14

### Added
- **Delete a bot from its own settings, on both shells.** It used to live only under Manage bots —
  a list of switches, which is where you go to hide a row, not to remove one. It is the last section,
  alone, and asks once.

- **Escape closes the topmost pane on the Mac**: full-screen computer → computer pane → bot panel →
  sidebar, in that order. A text field keeps Escape for itself, and a sheet keeps its own.

### Fixed
- **The sidebar's search field drops in *under* the row** instead of replacing it. In place, the
  field took the traffic lights' line and blended into the window's chrome.

- **The chat pill sits a few points off the window's top edge**, and the roster starts a little
  lower, so a selected first row is not half-faded before the list has scrolled.

- **"Use its initials instead" is gone from the add-bot sheet** — the screen exists to give a bot a
  face, and the row asked people to opt out of it.

- **"Show reasoning" off now hides reasoning, including what is already in the history.** The switch
  only gated the *live* reasoning block, and the client synthesises a reasoning row when a turn ends
  — so the text disappeared while it streamed and came back with the answer. Row visibility is one
  rule now (`TranscriptVisibility`), applied to both shells.

## [0.1.332] — 2026-11-14

### Fixed
- **The unread count no longer lags the banner.** The number travels in the same answer as the
  preview, but it is a *snapshot*: the bot list opens four or five reads inside three seconds, and a
  whole-map replace let a slower or failed answer put the count back to zero until the next 25 s
  sweep. A reply now puts a floor of one under that bot's count the instant the banner goes up (the
  next read replaces it with the host's exact number), only the newest read may set counts, a failed
  read leaves the last answer standing instead of emptying every badge, and a sweep already open is
  joined rather than repeated.

## [0.1.328] — 2026-11-14

### Fixed
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

## [0.1.324] — 2026-11-14

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

## [0.1.319] — 2026-11-14

### Fixed
- **The bot list's top edge, and the conversation's search field.** The "CHATS" label is gone — it
  said what the rows already were and cost a line between the bar's two buttons and the first bot,
  which now sits closer. The list fades out under the bar instead of meeting it with a hard seam:
  a row scrolling up dissolves into the canvas before it reaches the buttons. And "Search
  conversations" no longer opens a field drawn bare onto the transcript — the search bar is a glass
  pill, the same material as the bot pill above it.

## [0.1.316] — 2026-11-14

### Added
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

## [0.1.198] — 2026-11-13

### Added
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

## [0.1.191] — 2026-11-12

### Fixed
- **Compacting no longer fails when the phone goes to sleep.** A compaction is 2–3 minutes of *host*
  work (measured 74 s, 123 s, 163 s here) and iOS tears the socket down the moment the app leaves the
  foreground — the bridge logs `client_closed` 1001 about 200 ms after the request, and the app then
  told you "could not compact — The operation couldn't be completed. Software caused connection
  abort" while the host was still working. A lost answer is no longer treated as a refusal: the state
  stays "compacting… the host keeps working while the app is away", nothing can start a second one,
  and the next transcript the host hands back settles it — "conversation compacted" if it changed, and
  an honest "compacting did not report back" once five minutes have passed with no reconnect. A real
  refusal still says so, and an errno never reaches the screen as the reason.

## [0.1.187] — 2026-11-12

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

## [0.1.184] — 2026-11-12

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

- **CI stopped filling the account's Actions storage.** The plan includes 500 MB shared by caches and
  artifacts; the repo was at 100% with 1.4 GB of DerivedData caches and 214 build artifacts kept for 90
  days. Caching is gone from the workflow (`.build` and DerivedData are hundreds of megabytes a key),
  uploaded artifacts now expire in two days, and the repo's artifact/log retention is set to 3 days. A
  release still publishes from the artifact within minutes of the run finishing, so nothing about
  shipping changes — builds are simply slower.

- **The bridge is a managed service again, deployed from this repo.** The unit pointed at an older
  tree (`/opt/hermes-apps/Bridge`, system `python3`) while the running process came from
  `/opt/hermey/venv`, so a restart would have silently run different code — and its sandbox
  (`ReadWritePaths=/var/lib/hermes-bridge`) did not match the database the deployment actually uses.
  The unit now runs the venv, with `/var/lib/hermey` and the profile tree writable, `Restart=always`,
  and its state directory named in `bridge.env`, so paired devices survive a restart. Deploys are one
  command: `Tools/release/deploy_bridge.sh` installs `./Bridge` into that venv and restarts the unit.

### Changed
- **Loading a chat no longer queues behind duplicate requests.** One app launch was measured posting
  `profiles.list` twice, `session.list` five times and `model.options` three times inside three
  seconds — the last of those answering only after 3.7 s — and a reconnect repeated the burst. The
  gateway answers them one at a time, so the transcript waited on work nobody asked for. `GatewayClient`
  now collapses identical in-flight reads into a single round trip (`performRead`, keyed by method and
  params), remembers the model catalogue for two minutes because it costs the host seconds and changes
  only when the model does, and forgets everything it remembered when a write invalidates it
  (`profiles.configure`, `model.save_key`, `session.compress`). A refusal is never remembered.

## [0.1.171] — 2026-11-11

### Added
- **The Mac has the three per-bot panels the phone got.** ⋯ → **Workspace…** opens a sheet with the
  documents on the left and the document on the right — same viewer rules, same read-only rule: text in
  a monospaced reader, PDFs in `PDFView`, images at full size, and "no preview for this kind of file"
  instead of a blank pane. **Skills…** and **MCP servers…** are the same two lists with switches, read
  from the same host calls as the phone. All three share the window's single modal route, so opening one
  closes the others rather than queueing a sheet behind a sheet.

## [0.1.168] — 2026-11-11

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

## [0.1.164] — 2026-11-11

### Added
- **Skills and MCP servers, per bot, from the ⋯ menu.** Two new panels list what a bot may reach for —
  its skills under *Skills*, its MCP servers under *MCP servers* — each row a switch. Flipping one
  rewrites that bot's own config on the host, so it survives a relaunch and applies only to that bot:
  a disabled skill leaves the bot's index entirely (it cannot be called by name either), and a disabled
  MCP server stops being started for it. `profiles.configure` **replaces** both lists wholesale, so the
  app sends the complete set computed from `profiles.describe` — sending a one-item delta would silently
  switch off everything else the bot had.

## [0.1.160] — 2026-11-11

### Added
- **A workspace, with a viewer.** The ⋯ menu in a conversation now opens the bot's workspace: the
  documents it prepared, and the files you sent it, in one list with sizes and ages. Tap one and it
  opens — text as text, PDFs in a real PDF view, images at full bleed. Anything that cannot be laid out
  from its bytes (`.docx`, `.xlsx`) says so plainly instead of showing a blank page, and the list is
  strictly read-only: a stray gesture cannot tidy away a document a bot is still working on.
  The bridge grew `GET /v1/workspace/<profile>` and `GET /v1/workspace/<profile>/file?path=`; both are
  device-authenticated, refuse symlinks, refuse traversal, and serve byte ranges so a PDF can page.

## [0.1.155] — 2026-11-11

### Fixed
- **The chat no longer flickers while a reply streams, and scrolling up while a bot is working stays
  put.** Both had one cause: every streaming change scrolled the transcript, so a reply arriving at
  tens of tokens a second re-laid out the view tens of times a second, and the drag was overridden by
  the next token. Scrolling is now coalesced to one in flight at a time, and "at the bottom" comes
  from a measured distance rather than from a sentinel row appearing — with the reader's own intent
  (`followsStream`, set false the moment a finger drags) deciding whether a token may pull the view
  down at all.

## [0.1.152] — 2026-11-11

### Fixed
- **The macOS download no longer routes through GitHub's release CDN.** That CDN stalls mid-transfer
  on some networks — the transfer starts and stops making progress while the file is otherwise fine.
  CI now publishes the image to a small Pages repo as well, and the site links *that*: a plain `200`
  with a `Content-Length`, `accept-ranges`, and no redirect in front of it.
  <https://macblizzard.github.io/hermey-downloads/Hermey-macOS-unsigned.dmg> The release asset is
  still attached for anyone who prefers it.

## [0.1.149] — 2026-11-11

### Fixed
- **The Mac app launches on Apple silicon again.** CI built with `CODE_SIGNING_ALLOWED=NO`, so the
  universal binary carried no code signature at all — and an arm64 binary with no signature is not
  merely untrusted, the kernel refuses to execute it and macOS reports the app as **damaged**, which
  `xattr` cannot fix. The build now ad-hoc signs (`codesign --force --sign -`) before packaging, then
  mounts the finished image and verifies the signature and the `/Applications` shortcut from *inside*
  the artifact that gets uploaded. Ad-hoc needs no certificate and changes nothing about Gatekeeper's
  verdict: the first-launch quarantine step, and the `xattr` line, stay exactly as documented.

## [0.1.146] — 2026-11-11

### Changed
- **One Mac artifact: the `.dmg`.** The zip was a wrapper around the same `Hermey.app`, so CI now
  builds only the disk image and the release publishes only it. `publish_altstore.py` and the shell
  wrappers dropped `--mac-zip` in favour of `--mac-dmg`.

- **The unsigned first launch is documented where people look.** `docs/APPS.md` and the landing page
  both give the one-liner that authorises the app —
  `xattr -dr com.apple.quarantine /Applications/Hermey.app` — next to the right-click → Open route,
  because "cannot be opened because the developer cannot be verified" is the first thing a Mac user
  meets and the fix is not obvious.

## [0.1.143] — 2026-11-11

### Added
- **The Mac app is published as a `.dmg` as well as a `.zip`.** The image opens as a window with
  `Hermey` beside an `Applications` shortcut, so installing is one drag instead of unzip-then-move. The
  zip stays for scripts and build servers, and both are `hdiutil verify`-checked before upload. No
  notarization is involved: a disk image is not what Gatekeeper objects to — the unsigned app is, and
  it behaves the same inside an image as inside an archive.

## [0.1.137] — 2026-11-10

### Fixed
- **The chat scrolls again on iOS.** A `DragGesture(minimumDistance: 0)` on every message row took each
  touch from the scroll view, so nothing scrolled. The press location it was added for is not worth a
  dead chat: the card's arrow now points at the middle of the message's **visible** slice, measured from
  the row's frame against the screen, and the long press is the only gesture on a row again.

## [0.1.134] — 2026-11-10

### Fixed
- **The long-press card opens where your finger is.** It was anchored to the message's whole
  rectangle: for a long message that rectangle is taller than the screen, so "above the row" meant the
  top of the page. The card now anchors to the press point inside the row, and chooses its side from
  the pressed line rather than from the row's middle.

## [0.1.131] — 2026-11-10

### Fixed
- **The long-press card opens above a message at the bottom of the screen.** It was asked for with a
  fixed `arrowEdge: .top` — always below the row — and at the bottom of the screen there is no room
  below, so iOS placed what fitted and clipped the rest. The reactions are the first thing in the card,
  so they were exactly what disappeared, leaving slivers of colour along the top edge. The row now
  reports its own frame and the card opens on whichever side has room.

## [0.1.128] — 2026-11-10

### Fixed
- **Switching bots no longer flashes an empty chat.** Every switch cleared the pane and then waited
  for `resumeSession` — one round trip, 1–2 s, every time, including going back to a conversation that
  was on screen moments earlier. Nothing was cached. Each bot's transcript is now kept in memory (the
  eight most recent, oldest evicted), the pane paints that snapshot *before* anything is asked of the
  host, and the resume still runs and silently replaces it. A bot with nothing cached says "Opening
  cody…" instead of the "Start the conversation with cody" placeholder, which claimed the history was
  gone. "Reset conversation" evicts the snapshot, so a reset stays reset.

## [0.1.120] — 2026-11-10

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
  used. `HermeyIconButton` now shows its label as the tooltip (macOS only — iOS has no hover), the
  message action glyphs show theirs, and the composer's dismiss/cancel-reply/remove-attachment ✕, the
  jump-to-latest button and read-aloud are all named. Menu items and alert buttons are left alone:
  macOS does not draw tooltips inside menus.

## [0.1.115] — 2026-11-10

### Fixed
- **Double-clicking the top strip zooms the window everywhere, not just over the chat.** The stand-in
  title bar started 96 pt in — past the traffic lights — which left the band above the sidebar's
  search field dead: the same gesture that zoomed the window over the conversation did nothing there.
  It now covers the full width (the traffic lights are hit-tested by the window's own frame first),
  and a double-click follows the system preference (Desktop & Dock → "Double-click a window's title
  bar to": zoom, minimise, or nothing) instead of always zooming.

## [0.1.112] — 2026-11-10

### Fixed
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

## [0.1.109] — 2026-11-10

### Added
- **The phone can copy a code block — and both apps say when they did.** The desktop's code cards had a
  copy button that copied in silence, so the same press happened twice; the phone's had no button at
  all, leaving a long press and two drag handles as the only way to take a command off the screen. One
  shared `CodeCopyButton` now sits in both headers — language on the left, verb on the right — and the
  glyph turns into a tick where it stands for a second and a half, with a haptic, before going back.

## [0.1.106] — 2026-11-10

### Added
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

### Changed
- **The Mac's ⋯ menu no longer offers "Bot computer…"**: the header's own display button is the door,
  and a verb that repeats the button beside it made the menu read as a second toolbar.

## [0.1.100] — 2026-11-10

### Added
- **A picture you sent has no Save.** The viewer takes `canExport`: off for your own attachment (it is
  already on your disk — saving it back is busywork), on for a picture the host produced or one that
  arrived from elsewhere. Copy stays either way.

- **The footer fits a phone.** The bar was four text controls plus a primary button, so on a narrow
  screen `Done` was squeezed to `D…`; the secondary verbs are glyphs with 30 pt targets now, the
  report ("Copied", "Saved") is a word over the picture instead of a fifth control, and `Done` has
  `fixedSize` and the highest layout priority.

## [0.1.97] — 2026-11-10

### Added
- **Pictures open.** Clicking an attached image on the Mac, or tapping one on the phone, now opens a
  viewer instead of doing nothing: the picture at its own size with zoom (+/−, `Fit`, pinch), the
  pixel dimensions and file size, Copy, and — for pictures you did not send — Save (Mac: a save panel;
  phone: the share sheet). The
  bytes are shown exactly as they arrived — nothing is re-encoded. `ImageViewer` lives in
  `HermeyUI`, so the artifacts a host generates will open in the same one once they are rendered in
  a transcript (they are not drawn anywhere yet — the host sends no attachment metadata for its own
  replies, so that needs a host-side fetch, not a view).

## [0.1.93] — 2026-11-10

### Changed
- **Text is no longer washed out on the Mac.** `TypeScale.font` accepted a `Font.Weight` and dropped
  it: `.custom("Inter", size:)` cannot take one, so all 64 call sites that asked for `.semibold` or
  `.medium` drew the regular face — and Inter is not bundled, so the request fell back to the regular
  system face as well. The helper now asks for Inter only when the family is actually installed and
  otherwise draws the system face *at the weight requested*, at sizes rounded to a half point (a 0.85
  step used to draw 11.9 pt). The Mac composer's text view follows the same rule instead of asking
  `NSFont(name:)` for a family name, which always answered nil.

## [0.1.90] — 2026-11-10

### Changed
- **Opening the shared computer no longer clips the window.** The computer pane was a fixed 520 pt
  added to a window whose minimum width was computed for two panes, so the `HStack` overflowed and the
  shell was cut on *both* sides — the bot panel's labels on the left, the pane's buttons on the right.
  The pane now has a floor (320), an ideal (520) and a ceiling (760), the conversation hands back some
  width while it shares the window, the window's minimum follows the arrangement
  (`WindowLayout.minimumWidth`), and a narrow window is grown to fit rather than clipped.

## [0.1.87] — 2026-11-10

### Changed
- **The Mac stays paired across launches.** The pairing was written only to a data-protection
  Keychain item, which needs an application identifier — and the app ships unsigned, so
  `SecItemAdd` answered `errSecMissingEntitlement` (-34018), nothing was stored, and every relaunch
  asked for a fresh code from `hermey pair`. `PairingStore` now writes all three tiers it can
  (data-protection Keychain, login Keychain, and a `0600` file excluded from backups under
  Application Support) and reads the Keychain first, the file second; Settings says which one holds
  it, and the pairing log records the `OSStatus` when a tier refuses.

## [0.1.84] — 2026-11-10

### Changed
- **A pairing code is now accepted by the host instead of answered 422.** The Mac app sent the claim
  body as `publicKey`/`deviceName`; the host's model is `public_key`/`device_name`, so the request
  failed validation ("field required") and the sheet could only report the status code. The body and
  its field names moved to `PairClaimBody` in the kit (the phone had always spelled them itself), and
  refusals now carry the host's own reason — including FastAPI's array-shaped `detail`.

## [0.1.80] — 2026-11-10

### Changed
- **A code from `hermey pair` pairs on a Mac that has never paired.** A fresh Mac has no remembered
  host, so a bare eight-digit code parsed to nothing and the sheet called it "not a pairing code" —
  the digits were refused on the device and never reached the host; only the full `hermes://` link
  worked. `PairingLink.classify` now separates *a code with no address* from *not a code*, and the
  sheet answers the first by keeping the digits, opening Advanced and focusing the address field
  (which it then claims against). An address typed there also outranks one remembered from the last
  pairing, so re-pairing to a different host no longer needs the link.

## [0.1.75] — 2026-11-10

### Added
- **"N unread" in a bot chat's header strip:** the replies waiting in the *other* chats (other bots
  plus any group chat with new lines), refreshed while the chat is open. It sits beside the model
  chip and takes the entries count's place while it is showing — one count per row — and tapping it
  goes back to the list. It is **not** on the back button: a custom bar button is drawn by iOS inside
  its own glass capsule, which pushed the title off centre, and hiding the system back button
  disabled the edge-swipe, so that version could not ship.

### Changed
- **The three-dot menus open smaller.** The bar button is unchanged (a bare glyph, as before) — the
  popup was what was wrong: every row's label is shorter ("Search", "Compact", "Reset chat",
  "New group chat", "Hidden bots"), so the panel is narrower without losing a single verb.

- **The edge-swipe stopped going back.** Hiding the system back button to draw one that carried the
  unread bubble also switches off `interactivePopGestureRecognizer`, and the delegate it was handed
  back did not survive SwiftUI's layout passes. The bar keeps its system back button, so the swipe,
  the centred title and the bar's own chrome are the ones iOS draws.

## [0.1.66] — 2026-11-10

### Added
- **Unread badges on group chats.** A room row now carries the number of bot messages that landed
  since this device last read it, drawn on the room's faces exactly where a bot's count sits on its
  portrait. `groups.list` reports only each room's newest `seq`, so the count comes from the room's
  own log — fetched only for rooms that moved, and seeded rather than badged on first sight.

- **Settings → Diagnostics → View log** (About → *View log…* on the Mac): a timestamped, on-device
  record of what the app did — connects, socket drops and reconnects, failed session opens, refused
  sends, compaction failures, room reads — with Copy, Share and Clear. The log survives a relaunch,
  is capped at 400 lines, and mirrors to the system log for `log stream` on the Mac.

### Changed
- **A conversation has one gutter.** `Geometry.chatGutter` (16 pt on the phone, the Mac's 24 pt
  reading inset) is used by the transcript *and* the composer, in both a bot chat and a group chat.
  A room's composer used to sit flush against the screen edges while its bubbles stopped 12 pt in,
  and a bot's composer was 4 pt wider than its own text; both now line up.

## [0.1.63] — 2026-11-10

### Changed
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

## [0.1.58] — 2026-11-10

### Changed
- **A long bot conversation would not open at all on the phone.** `session.resume` answers with the
  whole transcript in one frame; this bot's chat is 3.4 MB, and iOS refuses to deliver a message
  that size — "could not open the conversation: … Message too long" — so the screen stayed empty
  while the socket reconnected to retry the same oversized frame. The bridge now ships the newest
  page with the resume (200 rows / 512 KB, whichever comes first) and serves older pages from its
  own copy of that resume, which the transcript reaches through a new **Load earlier messages** row
  on the phone and the Mac. Measured through the live bridge: 3,396,481-byte resume became 423,243
  bytes, and paging walked all 1,450 rows back to the start with no gap.

## [0.1.52] — 2026-11-10

### Changed
- **Bot computer clicked in the wrong place while zoomed, taps stopped registering, and the last
  reply duplicated itself row-by-row.** noVNC counted the zoom twice in every pointer coordinate
  (patched, with a check under `Tools/verify`); its touch recogniser was being fed a partial event
  stream and wedged, so this page now owns touch input outright; and the same paragraph arriving as
  a sealed commentary, an `message.interim` and a completion is now written once.

## [0.1.49] — 2026-11-10

### Changed
- **Right click landed away from the pointer, and pinching stopped working once its menu was open.**
  The click now goes where the pointer stands, not between the fingers; and noVNC's capture proxy
  div — laid over the whole page by its legacy `setCapture()` on a synthetic press — is released
  afterwards instead of swallowing every later touch.

- **The last reply appeared twice while it streamed.** A commentary sealed as `message.interim`
  became both a row and the live bubble; the bubble now prints only what the trailing row has not
  already said, and a completion that repeats that row does not append a second copy.

## [0.1.46] — 2026-11-10

### Added
- **Bot computer: right click.** A two-finger tap while in control is a right click at the point
  between the fingers (`MouseEvent.buttons: 2` through noVNC's own pointer path), with a one-time
  hint on take-over.

## [0.1.43] — 2026-11-10

### Changed
- **Bot computer: pinching froze the pointer, and there were two keyboard buttons.** The pinch
  swallowed the `touchend` noVNC needed to close the gesture it had opened, leaving a button pressed
  for the rest of the session; it now releases the pointer explicitly and lets the touchend through.
  The header keyboard button is gone — the floating ⌨ in the picture (touch devices only) is the one
  that works, because a tap in the page is the only focus WebKit accepts as a user gesture.

## [0.1.40] — 2026-11-10

### Changed
- **Typing, zooming and empty timestamps.** The Bot Computer keyboard did nothing (iOS raises keys
  only for an editable focused by a tap inside the page, so there is now a hidden text area, a real
  ⌨ button, and keys sent through noVNC's `sendKey`); there was no way to zoom (pinch 1×–4× and
  two-finger pan, with one finger still the remote pointer); and hiding tool calls left wordless
  assistant banner rows as blank bubbles with a timestamp — those rows are gone, and times now show
  only on messages with something to read.

## [0.1.37] — 2026-11-09

### Changed
- **Bot computer showed `NSURLErrorDomain Code=-999 "cancelled"` on opening.** That is a cancelled
  request, not a fault: the poll loop restarts on every state change and SwiftUI cancels the request
  in flight. Cancellations are now silent, other failures are one sentence instead of an NSError
  dump, and a healthy poll clears a stale strip.

## [0.1.34] — 2026-11-09

### Changed
- **Bot computer showed nothing at all.** The view loaded the `wss://` socket as if it were a web
  page, so the bundled viewer never ran — no script, no socket, no picture, and a spinner where the
  desktop should be. It now loads `hermey-novnc://local/botcomputer.html?ws=…` with the socket as a
  query parameter (one builder in HermesKit, tested), which is what the bridge log showed was missing:
  tickets minted, viewer socket never opened.

## [0.1.31] — 2026-11-09

### Changed
- **Bot computer: the window, the input and the black pane.** Three defects from the first hands-on
  test. The phone showed it in a sheet, so dragging the desktop dismissed it — it is now a full page
  with its own Close button. "Take over" enabled nothing: the flag was pushed into the page before
  noVNC's module had loaded and was never replayed, so pointer and keyboard stayed off; the page now
  keeps the flag and applies it on connect, and a keyboard button raises the keys on purpose. Taking
  over or handing back left a black pane: the viewer is now re-opened on a fresh ticket after every
  lease change, says "Connecting…" until the socket is up, retries a dropped stream twice, and shows
  the page's own error text instead of a silent black rectangle.

## [0.1.28] — 2026-11-09

### Changed
- **"Show tool calls" off now hides the cards.** The switch was wired to the card's *output*, so a
  user who turned tool calls off still saw every command in the chat and read the setting as broken.
  Off removes the tool rows from the transcript (history is untouched — turning it back on shows them
  again) and stops the running turn from drawing live cards either. The label now says what it does.

## [0.1.22] — 2026-11-09

### Added
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
