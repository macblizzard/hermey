# Changelog

All notable changes to Hermey are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions are the app's build versions.

## [Unreleased]

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
