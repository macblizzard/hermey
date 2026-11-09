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

1. Download `Hermey-macOS-unsigned.zip` from the [latest release](../releases/latest) and move
   `Hermey.app` to `/Applications`.
2. First launch: right-click the app → **Open** → **Open** again. macOS remembers the choice.
   Recent versions may instead require
   `xattr -dr com.apple.quarantine /Applications/Hermey.app` once.
3. The Mac app pairs exactly like the phone: run `hermey pair` on the host and paste the deep link
   (the Mac has no camera).

macOS 14+ is required (SwiftUI features the shell relies on).

## First run

- Add a server: paste `https://<host>.<tailnet>.ts.net:8443` or scan the QR.
- Enter the pairing code from `hermey pair`.
- The bot list is the home screen. Tap a bot for its endless conversation; the room list is behind the
  three-dot menu.

## Unpairing and revocation

Removing a device in the app deletes its key from the Keychain. On the host, revoking a device
invalidates its outstanding tickets immediately and leaves the other devices alone:

```bash
hermey doctor            # see what is paired and whether it is healthy
curl -s http://127.0.0.1:8787/v1/devices   # loopback only
```
