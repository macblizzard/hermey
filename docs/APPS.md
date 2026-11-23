# Installing the apps

Both apps are unsigned. That is a deliberate, stated trade-off until there is an Apple developer
account behind the project: the cost is a few extra taps on first install, and no recurring fee for
a client that talks only to your own machine.

## iOS

The release page carries an unsigned `.ipa`; you sign it with your own certificate.

1. Install **AltStore** ([altstore.io](https://altstore.io)) or **SideStore**
   ([sidestore.io](https://sidestore.io)) following their setup for your device.
2. Add this source to the app:
   `https://github.com/macblizzard/hermey/releases/latest/download/altstore.json`
   (It is a release asset on purpose: the latest release always serves the newest build, with no
   host of our own in the loop.)
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

## Reactions — one emoji, both devices

A reaction is kept by the host now, not by the device that made it: react on the Mac and the phone shows
it, react on the phone and the Mac shows it, live while the conversation is open. One emoji per message,
stored by the host and served by `GET` / `PUT /v1/reactions`.

- **Scoped, not global.** The host stores a reaction under the host, the bot and the session, so the
  same message in two bots is two reactions, and one host's bots are never confused with another's.
- **What a device already had goes up once.** Reactions kept locally before the host owned them are
  sent on the first run after the upgrade, so nothing is lost.
- **Unpaired, nothing changes.** With no host to ask, both apps keep using their local copy exactly as
  before.
- **Drafts and pins are still per-device.** Only reactions moved to the host.

## Desktop pets

On the Mac a bot can put its own picture on your desktop: no frame, no window background, just the icon
on your wallpaper, bobbing, tilting and occasionally hopping. Click it and a balloon opens with a field
— type a question, press Return, and the answer arrives in the balloon, scrollable, with a Copy button.
Escape or a click elsewhere dismisses it. Drag the pet anywhere and it remembers where you left it, per
screen; right-click → **Close pet** takes it off the desktop and switches off the same setting that
brought it back. Off by default, one switch per bot in that bot's settings, and Reduce Motion is
respected — no hops, and a gentler bob.

[`docs/DESKTOP-PETS.md`](DESKTOP-PETS.md) is the design it was built from: the window behaviour, the
decisions worth stating, and the corrections the build forced.

## Pictures in a message

Tapping an image in a reply opens it with every other image attached to that same message: the viewer
opens on the one you tapped and pages to its neighbours.

- **iPhone/iPad:** swipe sideways to turn the page; the bar carries a counter (`2 of 5`) naming your
  place. Swipe the picture down to put it away.
- **Mac:** ← and → turn the page, or click the chevrons beside the counter.

Each picture still pinches to zoom, and the page turns only on a sideways drag — the pull-down that
closes the viewer is deliberately not also a page turn.

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

**Full screen** is the arrows in the pane's header. On the Mac it puts the *window* into full screen —
the same thing the green button does — so the sidebar, the transcript and the traffic lights all go;
leaving it the system's way (green button, ⌃⌘F) puts the pane back in its panel. On the phone the pane
drops its own header, the status bar and the safe-area inset and runs edge to edge. Either platform
shows one floating bar over the picture: take over / hand back, zoom −/+, the level, **Fit**, and the
way out. `Esc` leaves full screen too (on the Mac the shell answers it, unless a text field has the
caret).

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
long it has been running. When the turn ends the same card holds for about six seconds saying "Done"
with the first ~120 characters of the reply, then goes.

- **One card per turn.** A second turn updates the card that is already up instead of stacking another.
- **Leftovers are swept.** A card outlives the process that made it, so one left by a quit mid-turn is
  cleared the next time the app launches.
- **A stalled turn stops claiming to work.** A card that goes half an hour without an update greys out;
  the next update brings it back.
- **iOS only.** The Mac has notifications and the badge instead. A phone with Live Activities switched
  off keeps working normally — the app records why no card appeared once in its client log (feature
  off, no ActivityKit, no turn running) rather than on every turn.

The extension is `dev.hermey.app.mobile.liveActivity`. It draws in the app's two palette colours as
literals, because an extension is its own process and linking the design system into it to read two
integers would only make it slow to launch.
