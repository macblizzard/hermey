# Third-party notices

Hermey is distributed under the licence in `LICENSE`. Parts of it are ported from other
open-source projects; those parts remain under their own licences, reproduced or referenced here.

## Bot avatar system

`Sources/HermeyUI/BotAvatar*.swift` — the eight shipped silhouette paths, the eye geometry, the
identity colour resolver and the per-activity motion — is a Swift port of the bot-avatar system in
**rakazo** (https://github.com/elie222/rakazo), specifically `packages/core/src/bot-avatar-shapes.ts`,
`packages/core/src/bot-avatar-colors.ts`, `packages/core/src/logo-avatar-activity.ts` and the organic
avatar block of `packages/ui-web/src/styles.css`.

rakazo is licensed under the Apache License, Version 2.0. A copy of that licence is at
https://www.apache.org/licenses/LICENSE-2.0 and the upstream repository ships it as `LICENSE`.

Changes from the original: the rendering is reimplemented in SwiftUI (a Path parser in place of the
browser's SVG renderer, SwiftUI animation in place of CSS keyframes); the geometry constants, colour
table, hash function and activity precedence rules are copied so the two implementations draw the
same face for the same bot identity.

This notice exists because Apache-2.0 requires attribution to travel with the derived work. It names
the upstream project only for that purpose; nothing in the product's own naming or design vocabulary
borrows from it.
