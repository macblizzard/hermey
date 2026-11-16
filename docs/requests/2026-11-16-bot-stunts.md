# Bot face: more movement — 2026-11-16

Source: Mohammad, 2026-11-16, in chat:

> "for next build i need more update on the bot animation. it now blinks and moves a bit, but its not
> enough, i need more movements specially for the bot icon besides thinking, more eye movements and
> some jumps and flips in between every few seconds while working"

Answered with two decisions, taken by him in the same conversation:

| # | Decision |
|---|---|
| B1 | **Playful** — jumps + 180°/360° flips, every few seconds. Not the restrained hop, not chaos. |
| B2 | **Working plus every busy state** — `working`, `thinking`, `reading`, `writing`, `computer`. |

## Today

`BotAvatarMotion.frame` is a faithful port of the reference's `logoAvatarFrame`: each state's base
posture and lid, its authored eye track, a per-identity breath, and a scheduled blink
(`3.2/8.9/14.2/21.1 s` or `4.1/11.5/20 s` inside a 24 s loop). The body barely moves — a 0.5 %
breath, plus the writing bob — which is the reference's own model, and until now was a rule this
project deliberately kept.

The result, in his words: "it now blinks and moves a bit, but it's not enough."

## Requested

1. More movement for the bot icon in every busy state, not only thinking.
2. More eye movement than the states' tracks give today.
3. Jumps and flips *between* the acting, every few seconds, while working.

## Decisions taken

- **A separate layer, not an edit to the port.** `Sources/HermeyUI/BotAvatarPerformance.swift` holds
  the stunts and `BotAvatarMotion.performedFrame(...)` composes them over `frame(...)`. The parity
  tests keep pinning the port, and the stunts are tested on their own terms
  (`Tests/HermeyUITests/BotAvatarPerformanceTests.swift`). This is the rule that keeps a future
  session from "restoring fidelity" by deleting the feature, and from "improving" the port.
- **Pure function of the clock.** No `@State`, no per-stunt flags: a `TimelineView` may ask for any
  instant, twice, out of order. Everything is a periodic window sampled from wall-clock time and the
  bot's own traits (`phase`, `side`).
- **Three clocks, not one.** The body performs on a 5.2–6.1 s beat (jump, then flip, alternating);
  the eyes dart on a 0.86–1.2 s clock; the squint has a 3.4–4.2 s one. One shared clock would make
  every face a metronome.
- **A stunt ends where it began.** Every track returns to zero inside its own window, so the frames
  either side are the state's own acting and nothing pops.
- **Amplitude capped in points.** `stuntTravel(forSize:)` gives 0.16 of the face at 16 pt and 0.05 at
  96 pt — 2.6 pt to 4.8 pt of leap — because the view's frame does not clip: a proportional leap on
  a 16 pt icon would draw over the word beside it in the working row.
- **Idle, waiting and error are untouched**, exactly as the reference draws them.

## Acceptance checks

1. A working face leaves the ground and turns over: ≥ 4 stunt windows and ≥ 2 flips in 12 s
   (`testAWorkingFaceLeavesTheGroundAndTurnsOver`).
2. Stunts are punctuation, not the whole cycle: the body rests in 60–95 % of frames
   (`testStuntsComeEveryFewSecondsRatherThanConstantly`; measured 75 %).
3. The eyes out-act the body: > 2× as many glances as stunts (measured 14 to 5).
4. Every busy state performs; idle/waiting/error produce a frame identical to the port's.
5. No stunt teleports: the pose cannot move further per drawn frame than a stunt's fastest segment
   (rotation compared modulo 360°), and one instant always yields the same face.
6. Two bots never perform in lockstep; Reduce Motion and the Appearance switch still close the face.
7. Measured, not asserted in prose: every threshold above was computed from a Python transcription of
   the sampler before the Swift was committed.
