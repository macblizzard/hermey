# Work order — Hermey batch 0.1.410 →

Owner: the build agent. Requested 2026-11-15 by the maintainer. Full item spec:
`docs/requests/2026-11-15-batch-410.md`. This file is the *order of work*: phases, what ships in
each, and what proves it. One release per phase, published from a green `main` CI run.

## Locked decisions (from 2026-11-15)

| # | Decision |
|---|---|
| R2 | **macOS only.** The bot panel that slides in from the right when the pill is clicked: the whole column starts ~30 pt below the window's top edge. (`Geometry.botPanelTopInset`) |
| R6 | Categories are stored **on the host** (bridge), so both apps agree. |
| R7 | Swipe actions are **iOS only**. |
| R1 | ⌘E is **macOS only**. |
| R3 | Search covers **transcripts only** — not memory, soul, notes or routines. |
| R5 | Tapping the bot-to-bot attribution opens a modal with the conversation between those two bots. |
| R12 | Backup is **configuration only** — no conversations. Its job is rebuilding the bots on a fresh Hermes install. |
| R14 | New item: the pill that opens the bot panel is hit-and-miss on macOS. |

## Phases

### Phase 1 — Bot menu (macOS) → release 0.1.410
- **R14** pill reliability: hit box is a static rectangle (the capsule's rounded ends were dead to
  the pointer) and the hover scale is gone (it moved the target during the spring); hover now
  reads as a brighter border and a deeper shadow.
- **R2** bot panel column starts `30 pt` below the window's top edge.
- **R1** ⌘E opens/closes the bot menu; the command lives in the Conversation menu and is disabled
  with no bot selected.
- Proof: CI green on macOS build; the three edits are visible in the app.

### Phase 2 — Log controls + iOS swipe → release 0.1.411
- **R4** `ClientLogView`: Refresh button, "Newest first / Newest last" toggle, order persisted.
- **R7** iOS bot rows: swipe left → Pin/Unpin, swipe right → Mark unread, icons only.
- Proof: both apps build; screenshots of the log sheet in both orders and of both swipe reveals.

### Phase 3 — Categories + list density → release 0.1.412
- **R6** host-side categories: bridge storage, `Add category` in the plus menu, per-bot category in
  Manage bots, collapsible groups, permanent Uncategorized, rename/delete.
- **R11** bot-list size slider in Appearance, default = today's size, live preview row.
- Proof: create → assign → collapse → relaunch keeps everything on both apps; slider extremes
  look intentional.

### Phase 4 — Search + bot-to-bot → release 0.1.413
- **R3** transcript search across all bots, findings list with snippets and jump-to-message.
- **R5** structured bot-to-bot rows (`Messaged <face> Name` / `Message from <face> Name`) plus the
  pair modal.
- Proof: a phrase that exists only inside a message is found and opens at the match; a bot-to-bot
  exchange reads correctly on both sides.

### Phase 5 — Settings + backup → release 0.1.414
- **R10** editable default soul for new bots, host-side, with "Restore Hermes default".
- **R12** export of all bots' configuration as one versioned JSON file, iOS share sheet + Mac save
  panel, no secrets in the file.
- Proof: custom default is applied at creation; export round-trips every field, and a test greps the
  fixture for token-shaped strings.

### Phase 6 — Windows + performance → release 0.1.415
- **R8** one window/sheet language: audit table in `docs/UI-WINDOWS.md`, tokens, before/after shots.
- **R9** long-conversation performance: measured baseline, fixes, before/after numbers.
- Proof: the audit table has no "misc" row; the numbers are in the release notes.

### Phase 7 — Audit → release 0.1.416
- **R13** security + bug audit, `docs/AUDIT-2026-11.md`, fixes with tests where possible.
- Proof: every finding fixed-with-test or deferred-with-reason; suites green.

## Working rules

- One phase at a time, in this order; a phase ships before the next one starts.
- Each phase: branch → PR → green CI → merge → publish → update here with the version and run id.
- A phase that cannot be verified is reported as unverified, never as done.
