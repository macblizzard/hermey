# Installing the apps

Both apps are unsigned. That is a deliberate, stated trade-off until there is an Apple developer
account behind the project: the cost is a few extra taps on first install, and no recurring fee for
a client that talks only to your own machine.

## iOS

The release page carries an unsigned `.ipa`; you sign it with your own certificate.

1. Install **AltStore** ([altstore.io](https://altstore.io)) or **SideStore**
   ([sidestore.io](https://sidestore.io)) following their setup for your device.
2. Add this source to the app:
   `https://macblizzard.github.io/hermey-downloads/altstore.json`
   (The Pages document is the app feed and is rewritten by every publish. The release-asset URL
   answers 404 whenever the newest release is a `hermeyd-v*` one — the host's own release series,
   which carries no `altstore.json` asset — so it is not a source a phone can rely on.)
3. Install **Hermey** from the source.

If you prefer to install the `.ipa` by hand, any signing tool that accepts an unsigned IPA works
(Sideloadly, Feather, or Xcode with a free Apple ID).

**The caveat, plainly:** a free Apple ID signs for ~7 days and then the app stops launching until it
is re-signed. AltStore/SideStore re-sign automatically in the background while you are on the same
network as the AltServer/SideServer; a paid developer account ($99/yr) extends that to a year. The
app itself needs no account, no Apple service and no internet beyond your tailnet.

## macOS

1. Download the disk image — a direct link, with no release-CDN redirect in front of it:
   <https://macblizzard.github.io/hermey-downloads/>
   The newest build is published there as `Hermey-macOS-<version>.dmg`, so the filename tells you
   which build you have; `Hermey-macOS-unsigned.dmg` on the same page is the *same bytes* under a
   name older links use, rewritten every publish.
   (the same artifact is attached to the
   [latest release](https://github.com/macblizzard/hermey/releases/latest), but GitHub's release
   CDN stalls mid-transfer on some networks). Open the image and drag `Hermey` onto the
   `Applications` shortcut in the same window.

   **How current is that page?** The publisher writes and verifies the file in GitHub on every
   release, but GitHub then builds the Pages site; serve time lags the release by tens of seconds to
   a few minutes. If the version in the filename is not the newest release, wait a minute and reload
   — Pages is a mirror of the release, and the release itself is always current.
2. The app is unsigned, so macOS quarantines it on first launch. Authorise it once, either way:

   ```bash
   # the quiet way, in Terminal
   xattr -dr com.apple.quarantine /Applications/Hermey.app
   ```

   or by hand: right-click `Hermey` → **Open** → **Open** again. macOS remembers the choice, so this
   is a first-launch step and not a routine one. If you move or re-download the app, the mark comes
   back with the new copy — run the command again.
3. The Mac app pairs exactly like the phone: run `hermeyd pair` on the host and enter the six-digit
   code under **Pairing code or link**. The code is single use and short-lived (the Mac has no camera).
   A hand-issued device token still works: open **Advanced — I have a device token** in the same
   sheet and paste the WebSocket URL, device ID and token.

macOS 14+ is required (SwiftUI features the shell relies on).

### Start at login

Settings → **Computer** → **Startup** → **Open Hermey at login** registers the app with
`SMAppService`, so the computer-use socket comes back after a reboot without opening the app by
hand. It opens the app at login; it does **not** wake a sleeping Mac — the app reconnects by itself
when the Mac wakes, which is a different thing.

## First run

- Add a server: paste `https://<host>.<tailnet>.ts.net` — serve-root, no port.
- Enter the pairing code minted on the host:
  `curl -fsS -X POST http://127.0.0.1:8788/v1/pair/start`.
- The bot list is the home screen. Tap a bot for its endless conversation; the room list is behind the
  three-dot menu.

## The model pill

On its own row under the message field, both apps show one pill: the bot's `provider/model` and how full
its context is, as `540k/1M Tokens`. It sits under the field rather than inside it, so it never reads as
part of what you type. Press it and the model picker opens — the same sheet the bot panel's **Model** row
opens on the Mac, and the drawer's on the phone.

- **The count arrives with a turn.** Usage comes back when a turn completes, so before the first reply
  the pill names the model alone rather than a made-up zero.
- **It never pushes the box around.** Typing cannot re-lay it out, and on a narrow phone it truncates
  to the model name instead of wrapping.
- **It replaces two chips.** The provider and the context count used to sit in separate chips under the
  pill; there is now one rule for the phone and the Mac.

## The bell, and what is waiting

The top row of the bot list holds the bell and the ＋. The bell wears a dot, not a number, when any bot
has replies this device has not read: *something is waiting* is what the dot says, and the list behind
it is where the names and counts live.

- **One row per bot that spoke**, most waiting first, each with the bot's picture, its name, how many
  replies are waiting, and the first line of its newest message. A bot with nothing waiting is not a
  row.
- **Opening a row is reading it.** Picking a bot from the list opens that conversation and clears its
  badge through the same call the bot's own dot uses, so the count, the dot and the list cannot
  disagree.
- **The phone has the same bell**, beside Settings, in a sheet sized to the rows it holds; the Mac draws
  it in a popover, from the bell or from ⇧⌘N.
- **The bars sit at the edges.** Settings is bottom left, search and the sidebar toggle bottom right,
  and the list fades into both ends over the same 26 points so no edge cuts a row.

## Updating from the app

The app checks once when it opens and does not put a window in front of you with the answer. When a
newer build exists, a **↓** button appears on the bot list's bottom bar, immediately left of search;
press it and the normal download-and-install window opens. Nothing installs without that press.

- **A skipped update stays quiet.** Choose Skip and the button stays away until the next launch, which
  checks again.
- **Asking for a check is unchanged.** Settings → **About** → *Check for Updates…* goes straight to the
  same window, as does the menu bar's own item: a check you asked for is never turned into a button
  instead.
- **The launch check never opens anything.** It reports the version to the bar and stops there, which
  is the window the button replaces.

## Desktop pets

On the Mac a bot can put its own picture on your desktop: no frame, no window background, just the icon
on your wallpaper, moving and blinking on its own. Click it for a frosted balloon — type, press Return,
read the answer, Copy it. It wears a badge when a reply lands while Hermey is minimised, drags anywhere
and stays there per screen, and right-click → **Close pet** switches it off. Off by default, one switch
per bot in that bot's settings. A pet is the bot's picture — or, once the bot has a face of its own (below), that face
in whatever state the bot is in.

[`docs/PETS.md`](PETS.md) is the reader's page: what a pet is, the switch, the balloon and a
troubleshooting table. [`docs/DESKTOP-PETS.md`](DESKTOP-PETS.md) is the design it was built from.

## A bot's own face

A bot can wear a face it draws instead of a picture you chose. Open that bot's settings and its
**Avatar** tab — the same editor on the Mac and the phone — and the top of it is a live preview of the
draft, drawn in the state the bot is actually in.

- **Twelve shapes to start from:** a blob, a box, a mug, a sprout, a cat, an egg, a bottle, a star, a
  droplet, an hourglass, an open book and a mushroom. Each is a solid silhouette with two eyes, chosen
  so the face still reads at the size of a row in the bot list. **Random** rolls a shape, a material and
  a colour together when you would rather meet one than pick one.
- **Paste a definition.** The JSON box takes an avatar in the
  [open-bot-avatar](https://github.com/DominikScholz/open-bot-avatar) v1 format — Dominik Scholz's
  MIT-licensed spec and renderer, which is where these shapes and the eye placement come from. A
  definition that does not validate is refused with its own reasons listed, and the bot keeps the face
  it had.
- **Nudge it by hand:** the colour, and the eyes' position, spacing and scale. Those edit the same
  definition the preview draws, so what you see is what gets saved.
- **Four materials.** **Solid** is the flat body it has always been. **Glass** is lit: the page behind
  it shows through, the body adds its own colour on top, and a soft glow rides the rim. **Matte** takes
  the shine away — felt or unglazed clay, dark soft edges and a faint grain. **Metal** puts one hard horizon line
  across the body with a narrow bright rim and no halo. What gets drawn follows the size: a row in the
  bot list carries the ramp, the rim and the contact band, the pet adds the streak and a glow kept
  inside its window, the editor's preview adds the eye's catchlight. The eight states tint the rim, and
  **Blocked** calms the colour instead of turning it red.
  Glass is a window rather than a painting now: the surface the avatar sits on shows through the body,
  and the body answers with its own colour — none over a light page, the material's full colour over a
  dark one — so a face never collapses into the pane behind it. The glow is measured from the body's own
  outline rather than from its pixels, so it fades in one smooth ramp instead of stepping into bands,
  and over a dark surface the face is lit a little from inside to keep its depth. What it does not do
  yet is bend the page behind it — that work is parked, and no shipped build refracts anything.
- **It moves like the picture faces.** A drawn face uses the same idle motion and the same pose for
  the state it is in, so choosing one does not make a bot go still.
- **One place to pick a face.** This tab is the only chooser: the old *Choose bot icon* control is
  gone from the Mac's About tab and the phone's identity section.
- **Save** stores the face. **Reset** deletes it, and the bot goes back to the picture or the
  shape-and-palette face it wore before.

The face is decoration and is allowed to be nothing else: this tab can write an avatar document and
cannot touch the bot's config or its soul. It draws in the bot list's row, in the chat header, and — on
the Mac — as the desktop pet.

## The eight words a bot wears

A bot is described with the same eight words everywhere now, from one table rather than three
vocabularies: **Idle**, **Thinking**, **Reading**, **Working**, **Using the computer**,
**Waiting for you**, **Blocked**, **Done**. The bot list's badge, the pet's own label, the chat header
and the iPhone's Live Activity all read that one word, so a row cannot say *Working* while the face says
something else — and the old three words (Working, Needs you, Finished) are gone.

- **Reading** is a tool that reads something: a file, a page, the transcript, a skill. **Using the
  computer** is a tool that drives a machine — the shared computer, a browser, a shell — and is the
  longest label anything here has to fit.
- **Working** is everything else a tool does, writing included, and it is also what a bot that is
  composing its answer shows.
- **Waiting for you** is a turn paused on you: a question, an approval, a take-over. **Blocked** is a
  run the host reported failed.
- **Done** is a finished turn, held for a few seconds before the face falls back to **Idle**. A
  background run is **Idle** on purpose — helper work should not look like a conversation.
- **No state wears a mark, and no state is smaller than another.** Every state is drawn at the one
  resting size with the one pair of eyes; a state says what it is doing with its own motion. **Blocked**
  used to give its body over to an exclamation mark and draw no eyes beside it — which made the one
  state a person most needs to notice the one that stopped looking like the bot. It now stops stiller
  than anything else and looks straight back, with a slow, deep pulse in the body, and keeps its face.
  **Waiting for you** leans aside and glances at what it waits on, with a slower blink and breathe than
  **Idle**. **Thinking** leans and looks up and away. **Done** turns once with its ribbons, at **Idle**'s
  size and with **Idle**'s eyes.

## The bot list's row menu

A row's **⋯** menu appears on hover, on selection and from the keyboard, and reserves no space when it
is hidden — a long bot name gets the width instead. Hovering a row also wakes its avatar for a small
hop, so a list of bots reads as alive before you open any of them.

## Keyboard shortcuts

Settings → **Shortcuts** (Mac) is one list of every keyboard action in the app, under four headings —
**Navigation**, **Conversation**, **Message** and **Window** — and the menu bar, the ⌘K palette's hints
and this pane all read the same table, so they cannot disagree about what a key does. Any row can be
re-recorded: press its field, then the combination you want (Escape cancels, ⌫ clears the row), and the
row's ↺ puts the shipped key back; **Restore Defaults** does that for every row at once. A combination
another action already owns is refused with the name of the action that has it, and macOS's own ⌘Q,
⌘W and ⌘, cannot be taken at all. A change applies immediately — the menus follow without a relaunch.
Three verb families arrived with the pane and had only buttons before: **Copy / Edit / Delete Last
Message** (⇧⌘C, ⌥⌘E, ⌘⌫), **Next / Previous Bot** (⌥⌘↓, ⌥⌘↑) and **Refresh Conversation** (⌘R).
The pane is Mac-only: a phone has no hardware keyboard to bind, so it has no such screen.

## Acting on a message

The per-message **⋯** is gone. On the Mac, right-click (or ctrl-click) anywhere on the row, or use the
menu bar's **Message Actions…** (**⌘⇧M**), which opens the same menu for the row the keyboard is on;
on the phone, long-press the message. A message row is a tab stop in between: the keyboard reaches it,
and the focused row shows a quiet hairline instead of a focus ring.

## Reactions — one emoji, both devices

A reaction is kept by the host now, not by the device that made it: one emoji per message, stored
against the host, the bot and the session, so a reaction on one device appears on the other while the
conversation is open. With no host to ask, both apps keep using their local copy; drafts and pins never
left the device.

## Pictures in a message

Tapping an image in a reply opens it with every other image attached to that same message: the viewer
opens on the one you tapped and pages to its neighbours.

- **iPhone/iPad:** swipe sideways to turn the page; the bar carries a counter (`2 of 5`) naming your
  place. Swipe the picture down to put it away.
- **Mac:** ← and → turn the page, or click the chevrons beside the counter.

Each picture still pinches to zoom, and the page turns only on a sideways drag — the pull-down that
closes the viewer is deliberately not also a page turn.

## Excel, Word and PDF files

Attach a document in either app and the bot reads it. The composer takes a `.xlsx`, `.docx` or `.pdf`
alongside pictures, the row in the transcript names the file and its size, and the text travels with your
message: a spreadsheet sheet by sheet with its rows, a Word document paragraph by paragraph with tables
flattened, a PDF page by page from its text layer.

- **What is sent** is the document's text, once, extracted on the host — every bot and both devices see
  the same thing. Bounds are stated rather than silent: 8 MiB per file, four files a message, 24 000
  characters a document, 50 PDF pages, 2 000 Word paragraphs and table rows, 12 sheets of 500 rows. A file
  cut at a bound says so in the host's log, and the block in the prompt names the sheet or page it came
  from.
- **Opening one** from the transcript needs no download step: the Mac opens Quick Look, the phone opens
  the share sheet with a preview. A file you sent is already cached on the device that sent it.
- **Scans are not read.** A PDF with no text layer is text-free to the host — no OCR runs, so photograph
  the page and send it as an image instead.
- **The way back.** A bot can write a file into its workspace and link it: the reply carries the same kind
  of row, downloaded from the host when you press it. Bots learn this from the bundled `office-files`
  skill, so a bot that has never read a file can still hand you one.

## Appearance and themes

Settings → **Appearance**. Several dark palettes, with **Midnight** the default, and **Parchment**
for daylight. Every window, sheet and tab tells the system which direction its palette faces, so
titles and grouped-row backgrounds follow the choice; a surface that shows a white title on a pale
background is missing that call.

## Arranging bot groups

Right-click a group's heading in the Mac's sidebar to **Move … Up** or **Move … Down**. The menu
items grey out at the ends of the list.

On the phone the same two verbs are on a category heading: long-press it, or tap the **⋯** at its
right edge — the visible door, since a long press on a heading is not something a person finds. The
phone has no **Pinned** or **Uncategorized** menu, because those two headings cannot move.

The arrangement is the host's, not the window's: it is stored beside the categories and both apps
read it, so a group moved on the Mac is in the same place on the phone. Until you move something the
list is alphabetical, which is how it has always been — so nothing has to be rearranged to look
like it did before this existed. A group created on the other device keeps its alphabetical place
until you arrange it, and **Pinned** and **Uncategorized** are the app's own headings: they sit
above and below the arrangement and never move.

The whole arrangement is written at once rather than "move this one up a slot", so two devices
arranging at the same time end up with the last arrangement written, never with two half-swaps.

## Renaming a group chat

The name lives on the room's row, not in the room's own chrome — a rename button beside the
transcript is the one place a name change does not look like it belongs.

- **iPhone/iPad:** long-press the room in the list → **Rename group chat…**
- **Mac:** right-click the room in the sidebar → **Rename group chat…**

The new name is sent to the host (`POST /v1/rooms/{id}/rename`, an engine `groups.rename`), so it is
the room's name everywhere, not a label this device keeps.

## Unpairing and revocation

Removing a device in the app deletes its key — from the Keychain, and from the `0600` file an
unsigned Mac build keeps it in. On the host, revoking a device invalidates its outstanding tickets
immediately and leaves the other devices alone:

```bash
sudo cat /var/lib/hermeyd/local.token                      # 0600, reminted at boot
curl -s -H "Authorization: Bearer $(sudo cat /var/lib/hermeyd/local.token)" \
     http://127.0.0.1:8788/v1/devices
```

`hermeyd` is loopback-only and every `/v1` route except `/v1/health` and `/v1/pair/start` requires
that local bearer.

## Bot computer

Both apps show the host's **shared** desktop — one screen, one browser profile, one set of logins for
every bot. There is no per-bot desktop to choose between.

- **iOS:** a bot's chat → ⋯ → **Bot computer**. The sheet shows a live thumbnail until you open it,
  then the live screen.
- **macOS:** the display button in the chat header (or ⋯ → **Bot computer…**) opens a right-hand
  panel beside the transcript; the panel's arrows put it full screen and bring it back.

The socket comes up **with the app**. Once *Let bots use this computer* is on, Hermey connects at
launch and redials on its own after a drop — you do not have to open Settings to bring computer use
back, and opening Settings is not what switches it on.

**Start screen** brings the desktop up (it otherwise starts itself on a bot's first
`computer_use`, and stops after 30 idle minutes). **Open screen** attaches the viewer; the picture is
live but input is inert. **Take over** asks the host for the control lease and enables keyboard and
pointer; **Hand back** returns it. Closing the pane hands control back on its own, so a bot is never
locked out by a viewer you forgot.

**Full screen** is the arrows in the pane's header. On the Mac it takes the *window* full screen, so the
sidebar, the transcript and the traffic lights all go; leaving it the system's way (green button, ⌃⌘F)
puts the pane back in its panel. On the phone the pane drops its own header, the status bar and the
safe-area inset. Either platform keeps one floating bar over the picture: take over / hand back, zoom
−/+, the level, **Fit**, and the way out. `Esc` leaves it too, unless a text field has the caret.

While the picture is bigger than its frame it zooms and pans between 1× and 5×:

- **Mac:** pinch on the trackpad (or ⌘/⌃-scroll) zooms about the pointer, two-finger scroll pans while
  zoomed, and ⌥-drag pans. A plain drag is still the remote mouse — that is what take-over is for.
- **iPhone/iPad:** pinch zooms about the fingers, one-finger drag moves the remote pointer, and two
  fingers drag the picture while zoomed (a two-finger tap is still the right click).

Panning is clamped to the picture's own edges, and the click mapping stays exact at any zoom: noVNC
measures the canvas's *rendered* rect and the page divides its own transform back out
(`HERMEY-PATCHES.md` in each bundle), so a tap on a button in the zoomed picture presses that button.

While you hold control every bot is refused (`human_has_control`), because they share the same
screen — that is what makes "sign in once, then let the bot continue" work.

## Notifications and badges

A bot's reply earns a notification when **that bot is not the one on screen** — a chat you are
reading has already told you. Both apps put the total waiting (bots and rooms together) on the
Dock tile or the app icon; zero clears it.

- Settings → **Notifications** (macOS) or **Settings → Replies** (iOS) has one switch and a
  per-bot **quiet** list. A quieted bot still counts on its row and in the badge; it just never
  buzzes. The switch is shared by the two apps, the system permission is not.
- **The banner wears the face you chose.** A notification's icon is the bot's own avatar rather than
  the old shape picture, drawn at whatever size the system asks for.
- **macOS** delivers a banner as soon as the host reports the reply, even while the app is in the
  background, and clicking it opens that conversation.
- **iOS** delivers a banner while the app is running. Once the phone has put the app away there is
  no socket to hear with, so replies fall back to a background refresh that iOS schedules — expect
  delays in the tens of minutes, and only while the phone is awake.
- **A relay closes that gap, and it is the only way a sideloaded build can.** Push to an app needs a
  credential for the team that signed it, and a personal or AltStore install has none. So the host
  posts the banner to an app that already holds one: install **Bark** (free, App Store), copy the
  address it shows, and paste it into Settings → **Replies** (iOS) or Settings → **Notifications**
  (macOS). **Send a test** proves it. From then on the host checks every bot's conversation on a
  ~10-second timer and pushes what is new, so a locked phone gets the banner promptly instead of
  whenever iOS decides to wake the app. Nothing is sent until an address is registered; the address
  is kept per device, and the same two rules still hold — a bot is never pushed about the chat on
  screen, and your own reply never rings.
- If a banner never appears, the first thing to check is the system permission: the app reports
  "Turned off in System Settings" (macOS) or offers a link straight to its iOS Settings page.

Drafts, pins and this switch are per-device; reactions are the host's now (see **Reactions** above), and
the unread counts themselves come from the host, so they survive a reinstall.

## Live Activity and the Dynamic Island

While a bot is working, an iPhone shows the turn on the lock screen and in the Dynamic Island: one
card naming the bot, what it is doing (thinking, the tool it is running, streaming the reply) and how
long it has been running. When the turn ends the card stays and says "Done" with the first ~120
characters of the reply.

- **It stays until you remove it.** The card is never dismissed by the app: it keeps its place in the
  Dynamic Island and on the lock screen until it is swiped away (or the system's own eight-hour limit is
  reached), so an answer you asked for is still there when you pick the phone up.
- **One card per turn.** A second turn updates the card that is already up instead of stacking another.
- **Leftovers are swept.** A card outlives the process that made it, so one left by a quit mid-turn is
  turned into "Done" the next time the app launches rather than left claiming to work.
- **Glass, not a panel.** The card carries no fill of ours: the lock screen's own material shows through,
  with the bot's accent on the mark and the status line.
- **iOS only.** The Mac has notifications and the badge instead. A phone with Live Activities switched
  off keeps working normally — the app records why no card appeared once in its client log (feature
  off, no ActivityKit, no turn running) rather than on every turn.

The extension is `dev.hermey.app.mobile.liveActivity`. It draws in the app's two palette colours as
literals, because an extension is its own process and linking the design system into it to read two
integers would only make it slow to launch.
