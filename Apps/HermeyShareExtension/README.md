# Hermey share extension

Share text, links and images from any iOS app into a bot chosen **inside the share sheet**.

The extension never talks to a Hermey host. It has no pairing, no token and no socket — it is
launched into another app's process for a few seconds. It reads a bot list the app left in an App
Group container, copies the shared bytes there, and opens `hermey://share`. The app drains the
container and sends through its normal path.

```
  host app ──share sheet──▶ HermeyShareExtension
                                   │ writes Share/Inbox/Assets/<id>/… + Share/Inbox/<id>.json
                                   │ opens hermey://share
                                   ▼
                            HermesMobile
                                   │ ShareInboxReceiver.drain { payload in … }
                                   ▼
                     POST /v1/bots/{profile}/message   (existing app path)
```

## Files

| Path | Target | What it is |
| --- | --- | --- |
| `Apps/HermesShare/SharePayload.swift` | both | `SharePayload` / `ShareAttachment`, version-checked, `Codable` |
| `Apps/HermesShare/ShareInbox.swift` | both | Every path in the App Group, plus write/claim/finish/prune |
| `Apps/HermesShare/ShareBotSnapshot.swift` | both | The picker's only source of truth (written by the app) |
| `Apps/HermeyShareExtension/*.swift` | extension | View controller, SwiftUI sheet, importer, composer |
| `Apps/HermeyShareExtension/Info.plist` | extension | `com.apple.share-services`, activation rule |
| `Apps/HermesMobile/Views/ShareInboxReceiver.swift` | app | Drains the inbox, idempotently |

## project.yml — what the parent must add

### 1. The extension target

```yaml
  HermeyShareExtension:
    type: app-extension
    platform: iOS
    sources:
      - path: Apps/HermeyShareExtension
        # `INFOPLIST_FILE` supplies the plist; adding it as a resource would bundle a second copy.
        excludes:
          - "Info.plist"
          - "README.md"
      # The same three files the app compiles: one schema, no drift.
      - path: Apps/HermesShare
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.hermey.app.mobile.share
        PRODUCT_NAME: HermeyShareExtension
        INFOPLIST_FILE: Apps/HermeyShareExtension/Info.plist
        CODE_SIGN_ENTITLEMENTS: Apps/HermeyShareExtension/HermeyShareExtension.entitlements
        APPLICATION_EXTENSION_API_ONLY: YES
        GENERATE_INFOPLIST_FILE: NO
        SKIP_INSTALL: YES
        TARGETED_DEVICE_FAMILY: "1,2"
```

Do **not** give this target an `info:` block: XcodeGen would regenerate the plist from properties
and drop the `NSExtension` dictionary, and the target would build but never appear in a share sheet.

### 2. The app target (`HermesMobile`)

```yaml
    sources:
      - path: Apps/HermesMobile
      - path: Apps/HermesShare            # ← add this line
      # … existing entries …

    dependencies:
      # … existing entries …
      - target: HermeyShareExtension      # embeds it in PlugIns/, which is what makes it install
```

### 3. The App Group — both targets, same string

`group.dev.hermey.app` must appear in **both** entitlements files. The extension's is in this
directory. For the app, either add the file or let XcodeGen write it:

```yaml
    entitlements:
      path: Apps/HermesMobile/HermesMobile.entitlements
      properties:
        com.apple.security.application-groups:
          - group.dev.hermey.app
```

The string is also `ShareInboxStorage.appGroupIdentifier`. All three must match; a mismatch shows
up as an empty picker ("Open Hermey once…") even though the app works.

## App wiring (not in these files)

```swift
// 1. Publish the picker's list whenever the bot list changes, and once at launch.
try? ShareBotSnapshotStore.publish(model.bots.map { ($0.id, $0.displayName) },
                                   defaultBotID: model.selectedBotID)

// 2. Drain on launch and on every foreground.
await ShareInboxReceiver.shared.drain { payload in
    // payload.text / payload.urlString / payload.messageText, and payload.attachments
    // resolved through ShareInboxReceiver.shared.data(for:payloadID:)
    // → hand to the existing send path; return false if the host is unreachable
}

// 3. In `.onOpenURL`, next to the existing `hermey://bot/<profile>` handling.
if ShareInboxReceiver.isShareInboxURL(url) {
    Task { await ShareInboxReceiver.shared.drain(accept: deliverShared) }
}
```

`drain` is safe to call from both places at once: a payload is claimed by rename before it is
handed over, and acceptance writes a marker before the file is deleted, so a relaunch with a stale
file deletes it instead of sending twice.

The accept closure must have read any attachment bytes it needs before it returns true — the payload
descriptor is deleted immediately after. The bytes themselves stay for a day (reclaimed by
`prune`) so an upload that is still in flight is not pulled out from under; call
`ShareInboxStorage.removeAssets(_:)` once the host has them.

## Payload schema (v1)

```json
{
  "version": 1,
  "id": "0F0E…",
  "createdAt": "2026-11-22T18:04:11Z",
  "botID": "cody",
  "botName": "Cody",
  "text": "look at this",
  "urlString": "https://example.com/article",
  "attachments": [
    { "id": "…", "kind": "image", "fileName": "….jpeg",
      "typeIdentifier": "public.jpeg", "originalName": "IMG_0042.HEIC", "byteCount": 182344 }
  ]
}
```

Bytes live at `Share/Inbox/Assets/<payload id>/<fileName>` inside the App Group — never a URL from
the share sheet's temporary directory.

A reader refuses any `version` it did not write (`SharePayloadError.unsupportedVersion`) and parks
the file in `Share/Inbox/Rejected/` rather than guessing at its fields.

## What the user sees

| Situation | Text |
| --- | --- |
| Sheet title | **Send to Hermey** |
| No snapshot yet | "Open Hermey once so it can list your bots here." |
| Snapshot older than 7 days | "The bot list is out of date. Open Hermey to refresh it, then share again." |
| Snapshot with no bots | "No bots yet. Add one in Hermey, then share again." |
| Nothing shareable | "Nothing to send: this item has no text, link or image." |
| Container write failed | "Hermey has no shared storage yet. Open Hermey once, then share again." |
| Oversized item | "1 item was too large to add." |

Buttons: **Cancel**, **Send** (disabled until a bot is selected and something is present).

## Only a device can confirm

- The extension appearing in the system share sheet for Safari / Photos / Files.
- The picker rendering at the sheet's real height, and the share sheet's own chrome above it.
- `extensionContext.open("hermey://share")` actually foregrounding the app. On refusal the payload
  is still queued and delivers on the next launch — the code treats that as success, not failure.
- The App Group container being created and visible to both binaries (a signing/entitlement fact).
