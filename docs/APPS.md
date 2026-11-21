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
3. The Mac app pairs exactly like the phone: mint a code on the host with
   `curl -fsS -X POST http://127.0.0.1:8788/v1/pair/start` and enter the eight digits under
   **Pairing code or link**. The code is single use and short-lived (the Mac has no camera).
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

## Appearance and themes

Settings → **Appearance**. Eight palettes: **Midnight** (the default), Graphite, Gruvbox, Tokyo
Night, Catppuccin, Dracula, Nord, and **Parchment** — a light theme taken from the colours of the
project's own site, for daylight and for screenshots.

A theme is more than a colour set. The app draws its own colours from the palette, but the system
draws navigation titles, section headers and footers, grouped row backgrounds and the labels on its
own controls — so every surface that is presented separately (a window, a sheet, a tab's navigation
stack) tells the system which direction the palette faces. That is why Parchment is readable rather
than white-on-cream; it is also the bug that took three releases to corner, so if a surface ever
shows a white title on a pale background, that surface is the one missing the call.

Dark palettes are unchanged by any of this: they say "dark" and get dark.

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

Reactions, drafts, pins and this switch are per-device; the unread counts themselves come from the
host, so they survive a reinstall.
