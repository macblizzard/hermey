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

1. Download `Hermey-macOS-unsigned.dmg` — a direct link, with no release-CDN redirect in front of it:
   <https://macblizzard.github.io/hermey-downloads/Hermey-macOS-unsigned.dmg>
   (the same file is attached to the [latest release](../releases/latest), but GitHub's release CDN
   stalls mid-transfer on some networks). Open the image and drag `Hermey` onto the `Applications`
   shortcut in the same window.
2. The app is unsigned, so macOS quarantines it on first launch. Authorise it once, either way:

   ```bash
   # the quiet way, in Terminal
   xattr -dr com.apple.quarantine /Applications/Hermey.app
   ```

   or by hand: right-click `Hermey` → **Open** → **Open** again. macOS remembers the choice, so this
   is a first-launch step and not a routine one. If you move or re-download the app, the mark comes
   back with the new copy — run the command again.
3. The Mac app pairs exactly like the phone: run `hermey pair` on the host and paste what it prints
   into **Pairing code or link** — the eight digits, or the whole `hermes://` link (the Mac has no
   camera). The code is single use and lives ten minutes.
   A hand-issued device token still works: open **Advanced — I have a device token** in the same
   sheet and paste the WebSocket URL, device ID and token.

macOS 14+ is required (SwiftUI features the shell relies on).

## First run

- Add a server: paste `https://<host>.<tailnet>.ts.net:8443` or scan the QR.
- Enter the pairing code from `hermey pair`.
- The bot list is the home screen. Tap a bot for its endless conversation; the room list is behind the
  three-dot menu.

## Unpairing and revocation

Removing a device in the app deletes its key — from the Keychain, and from the `0600` file an
unsigned Mac build keeps it in. On the host, revoking a device invalidates its outstanding tickets
immediately and leaves the other devices alone:

```bash
hermey doctor            # see what is paired and whether it is healthy
curl -s http://127.0.0.1:8787/v1/devices   # loopback only
```

## Bot computer

Both apps show the host's **shared** desktop — one screen, one browser profile, one set of logins for
every bot. There is no per-bot desktop to choose between.

- **iOS:** a bot's chat → ⋯ → **Bot computer**. The sheet shows a live thumbnail until you open it,
  then the live screen.
- **macOS:** the display button in the chat header (or ⋯ → **Bot computer…**) opens a right-hand
  panel beside the transcript; the panel's arrows put it full screen and bring it back.

**Start screen** brings the desktop up (it otherwise starts itself on a bot's first
`computer_use`, and stops after 30 idle minutes). **Open screen** attaches the viewer; the picture is
live but input is inert. **Take over** asks the host for the control lease and enables keyboard and
pointer; **Hand back** returns it. Closing the pane hands control back on its own, so a bot is never
locked out by a viewer you forgot.

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
  no socket to hear with, so replies are picked up by a background refresh that iOS schedules —
  expect delays in the tens of minutes, and only while the phone is awake. Immediate delivery on a
  locked phone would need an APNs entitlement, which an AltStore/personal-team install cannot have.
- If a banner never appears, the first thing to check is the system permission: the app reports
  "Turned off in System Settings" (macOS) or offers a link straight to its iOS Settings page.

Reactions, drafts, pins and this switch are per-device; the unread counts themselves come from the
host, so they survive a reinstall.
