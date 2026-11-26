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

## Drawn avatars (open-bot-avatar)

`Sources/HermeyUI/OpenBotAvatar/*.swift` — the definition parser and validator, the plane and eye
matrix, the per-state body behaviour and marks, the blink curve, the seeded hash, the material layer
table and the twelve preset shapes — is a Swift port of **open-bot-avatar**
(https://github.com/DominikScholz/open-bot-avatar), and the `definition` document a bot stores is that
project's v1 format unchanged. `Sources/HermesKit/BotAvatarActivity.swift` ports the same project's
activity precedence rules, and `hermeyd/src/bot_avatar.rs` mirrors its validation.

open-bot-avatar is licensed under the MIT License:

```
MIT License

Copyright (c) 2026 Dominik Scholz

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial
portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

Changes from the original: the renderer is SwiftUI `GraphicsContext` rather than canvases; the
materials are a layer table rather than a shader; and the glass treatment follows the specification in
this repo rather than the upstream renderer's lighting. The geometry, the state semantics, the eye
pair and the document format are ported so a definition written in upstream's editor pastes in
unchanged.

