import Foundation
import HermesKit

/// The stunts a busy face performs between its authored acting: a jump, a flip, and the small eye
/// business that makes a wait feel watched.
///
/// ## Why this exists, and why it may disagree with the reference
///
/// The shipped face is the reference's own model: the body breathes, the eyes run that state's
/// authored track, and apart from the writing bob the body does not move at all. Mohammad's report
/// of 2026-11-16 was that this is not enough — *"it now blinks and moves a bit, but it's not enough,
/// I need more movements … more eye movements and some jumps and flips in between every few seconds
/// while working"* — so the face performs. The reference is still the source of the **acting**
/// (`BotAvatarMotion.frame`), and a stunt is composed *over* that frame rather than mixed into it.
/// Keeping the two apart is what lets `BotAvatarMotion.frame` go on being the port the parity tests
/// pin, with these additions testable on their own terms.
///
/// ## The two rules that keep it from looking broken
///
/// - **Every number here is a pure function of the clock and the bot's own traits.** A `TimelineView`
///   may ask for any instant, twice, out of order; a "which stunt am I in" flag is state, and state
///   desynchronises the moment two faces share a clock or a window is occluded. Each stunt is one
///   periodic window sampled from wall-clock time instead, which is the same discipline the blink
///   schedule uses.
/// - **A stunt ends where it began.** Every track returns to zero inside its own window, so the
///   frames either side are the state's own acting again and nothing pops.
///
/// Idle keeps its float, `waiting` keeps its held look (it is asking the person for something), and
/// `error` rests: those are the states where a backflip would be a lie or a distraction.
///
/// ## Cost
///
/// Nothing here changes the redraw rate — it is the same 30 Hz `TimelineView`, sampling about twenty
/// more numbers per frame, with no new layers, paths or effects. The frame budget measured in
/// `references/performance-cpu.md` is unchanged.
public struct BotAvatarPerformance: Equatable, Sendable {
    /// How the stunt moves the body, added to the state's own pose.
    public var body: BotAvatarPose
    /// How the stunt moves the eyes, added to the state's own eye pose.
    public var eyes: BotAvatarEyePose

    public init(body: BotAvatarPose = .rest, eyes: BotAvatarEyePose = .rest) {
        self.body = body
        self.eyes = eyes
    }

    /// Nothing to add: the state's own acting is the whole performance.
    public static let none = BotAvatarPerformance()

    /// Whether this instant has no stunt in it at all.
    public var isEmpty: Bool { body.isRest && eyes == .rest }

    /// Lay this performance over the reference's frame.
    ///
    /// Translation, rotation and brightness travel by addition; scale composes by multiplication,
    /// because the reference already uses scale for the breath and a stunt's squash has to multiply
    /// that rather than replace it. Composing the other way round would flatten the breath the
    /// moment a face jumped.
    public func applied(to frame: BotAvatarMotion.Frame) -> BotAvatarMotion.Frame {
        BotAvatarMotion.Frame(
            body: BotAvatarPose(translateX: frame.body.translateX + body.translateX,
                                translateY: frame.body.translateY + body.translateY,
                                rotate: frame.body.rotate + body.rotate,
                                scaleX: frame.body.scaleX * body.scaleX,
                                scaleY: frame.body.scaleY * body.scaleY,
                                brightness: frame.body.brightness + body.brightness),
            eyes: BotAvatarEyePose(offsetX: frame.eyes.offsetX + eyes.offsetX,
                                   offsetY: frame.eyes.offsetY + eyes.offsetY,
                                   scaleX: frame.eyes.scaleX * eyes.scaleX,
                                   scaleY: frame.eyes.scaleY * eyes.scaleY)
        )
    }
}

extension BotAvatarMotion {

    // MARK: - Which states perform

    /// Every busy state performs.
    ///
    /// Asked for as "working + every busy state" (2026-11-16). `idle` is a bot doing nothing and
    /// gets no stunts; `waiting` is looking straight at the person and holding still is the message;
    /// `error` rests, as the reference rests it.
    public static func performs(_ activity: BotAvatarActivity) -> Bool {
        switch activity {
        case .working, .thinking, .reading, .writing, .computer: return true
        case .idle, .waiting, .error: return false
        }
    }

    // MARK: - How big a stunt is

    /// How far a face of this side travels in a stunt, as a fraction of its own box.
    ///
    /// A jump is a distance, so it starts life as a fraction — but the face's frame does not clip,
    /// and a leap taller than its row would draw over the word beside it. The fraction is therefore
    /// capped so the leap is about 2.6 pt at 16 pt and 4.8 pt at 96 pt: the same 3–5 pt of travel at
    /// every size, which is what keeps the 16 pt face in the working row lively without pushing it
    /// out of the row.
    public static func stuntTravel(forSize side: Double) -> Double {
        guard side > 0 else { return 0.08 }
        return min(0.16, max(0.05, 3.6 / side))
    }

    // MARK: - The schedule

    /// One cycle of the beat: two stunts, a jump then a flip, 5.2–6.1 s apart per bot.
    ///
    /// The phase is the bot's own, so two faces in one list never jump together, and the floor is
    /// high enough that a face reads as *alive* rather than as twitching.
    static func stuntCycle(_ traits: BotAvatarMotionTraits) -> Double {
        5.2 + 0.9 * traits.phase
    }

    /// How long each stunt takes, in seconds.
    ///
    /// Both are well under half a beat, which is the point: the stunt is punctuation, and most of
    /// the beat is the state's own acting.
    static let jumpDuration: Double = 0.62
    static let flipDuration: Double = 0.66

    // A jump: settle, crouch, launch, apex, fall, land with squash, recover.
    // Progress is 0…1 of `jumpDuration`; `jumpY` is in units of `stuntTravel` (negative is up).
    static let jumpY: [(Double, Double)] = [
        (0, 0), (0.14, 0.22), (0.30, -0.55), (0.46, -1), (0.62, -0.5),
        (0.78, 0), (0.84, 0.18), (1, 0),
    ]
    static let jumpSquashY: [(Double, Double)] = [
        (0, 1), (0.14, 0.86), (0.30, 1.12), (0.46, 1.03), (0.62, 0.97),
        (0.78, 1), (0.84, 0.87), (1, 1),
    ]
    static let jumpSquashX: [(Double, Double)] = [
        (0, 1), (0.14, 1.12), (0.30, 0.92), (0.46, 0.98), (0.62, 1.01),
        (0.78, 1), (0.84, 1.12), (1, 1),
    ]
    /// A couple of degrees of lean at the apex: enough that the face is not a stamp moving up and
    /// down on rails.
    static let jumpTilt: [(Double, Double)] = [(0, 0), (0.30, 0), (0.46, -2.5), (0.78, 0), (0.84, 1.6), (1, 0)]
    /// A brief lift in brightness on the landing, so the landing reads even at 16 pt.
    static let jumpGlow: [(Double, Double)] = [(0, 0), (0.78, 0), (0.84, 0.07), (1, 0)]

    // A flip. `rollTurn` is a fraction of a full turn; `twistTurn` goes out and back, which reads as
    // a shoulder-shrug rather than a spin and keeps the two flips from becoming one move repeated.
    static let rollTurn: [(Double, Double)] = [(0, 0), (0.08, 0), (0.52, 1), (1, 1)]
    static let twistTurn: [(Double, Double)] = [(0, 0), (0.10, 0), (0.34, 0.5), (0.50, 0.5), (0.74, 0), (1, 0)]
    static let flipY: [(Double, Double)] = [
        (0, 0), (0.30, -0.35), (0.55, -0.45), (0.80, 0), (0.88, 0.12), (1, 0),
    ]
    /// The tuck: a face that spins without gathering itself looks like a picture being rotated.
    static let flipTuck: [(Double, Double)] = [(0, 1), (0.26, 0.90), (0.52, 0.94), (0.72, 1.06), (1, 1)]

    // The eyes' own faster clock. A saccade is a fast move to a target, a hold, and a return.
    static let saccadeDuration: Double = 0.55
    static let saccadeTravel: [(Double, Double)] = [(0, 0), (0.05, 1), (0.70, 1), (0.86, 0), (1, 0)]
    /// The bigger, two-step glance that fires every fifth saccade.
    static let doubleTakeX: [(Double, Double)] = [
        (0, 0), (0.05, 0.06), (0.22, 0.06), (0.28, 0.14), (0.55, 0.14), (0.64, 0), (1, 0),
    ]
    static let doubleTakeY: [(Double, Double)] = [
        (0, 0), (0.05, -0.02), (0.22, -0.02), (0.28, 0.05), (0.55, 0.05), (0.64, 0), (1, 0),
    ]

    /// A quick squint on its own slow clock: the face concentrating, not blinking.
    static let squintDuration: Double = 0.20
    static let squintLid: [(Double, Double)] = [(0, 1), (0.15, 0.62), (0.55, 0.62), (0.8, 1), (1, 1)]

    /// Where a saccade may land, in fractions of the eye box. The list is walked in order, so a bot's
    /// glances are its own replayable sequence rather than a random walk.
    struct Dart {
        var x: Double
        var y: Double
    }

    static let darts: [Dart] = [
        Dart(x: 0.10, y: -0.03),
        Dart(x: -0.12, y: 0.02),
        Dart(x: 0.05, y: -0.09),
        Dart(x: -0.07, y: 0.07),
        Dart(x: 0.13, y: 0.04),
        Dart(x: -0.05, y: -0.06),
        Dart(x: 0.03, y: 0.10),
        Dart(x: -0.13, y: -0.02),
    ]

    /// A non-negative remainder, so a clock that starts before the reference date still lands on a
    /// legal index instead of crashing on a negative subscript.
    static func wrapped(_ value: Int, _ modulo: Int) -> Int {
        guard modulo > 0 else { return 0 }
        let remainder = value % modulo
        return remainder < 0 ? remainder + modulo : remainder
    }

    // MARK: - Sampling

    /// The stunt in progress at an instant, for a face drawn at `side` points.
    ///
    /// Three clocks, deliberately not one: the body jumps and flips on the beat, the eyes dart on a
    /// faster one, and the squint on a slower one. A single clock would make every face perform a
    /// metronome — jump, glance, jump, glance — which is the shape of a machine, not of something
    /// doing work.
    public static func performance(activity: BotAvatarActivity,
                                   traits: BotAvatarMotionTraits,
                                   at time: Double,
                                   side: Double) -> BotAvatarPerformance {
        guard performs(activity) else { return .none }

        let travel = stuntTravel(forSize: side)
        let cycle = stuntCycle(traits)
        let beat = cycle / 2

        // The beat we are in, and how far into it. `rounded(.down)` keeps the beat index and the
        // local offset consistent for negative times too, which is what the two `+ beat` guards are
        // for: floating point at the wrap can land a hair below zero.
        let beatIndex = Int((time / beat).rounded(.down))
        var local = time - Double(beatIndex) * beat
        if local < 0 { local += beat }
        if local >= beat { local -= beat }

        var body = BotAvatarPose.rest
        var eyes = BotAvatarEyePose.rest

        if beatIndex % 2 == 0 {
            // Jump.
            if local <= jumpDuration {
                let progress = local / jumpDuration
                body.translateY = sample(jumpY, at: progress) * travel
                body.scaleX = sample(jumpSquashX, at: progress)
                body.scaleY = sample(jumpSquashY, at: progress)
                body.rotate = sample(jumpTilt, at: progress) * (beatIndex % 4 == 0 ? 1 : -1)
                body.brightness = sample(jumpGlow, at: progress)
            }
        } else if local <= flipDuration {
            // Flip: a full roll on one beat, an out-and-back twist on the next, alternating which way
            // it turns so a face never spins the same direction forever.
            let progress = local / flipDuration
            let spin = (beatIndex % 4 == 1 ? 1.0 : -1.0) * traits.side
            let turns = wrapped(beatIndex, 4) == 1
                ? sample(rollTurn, at: progress)
                : sample(twistTurn, at: progress)
            body.rotate = turns * 360 * spin
            body.translateY = sample(flipY, at: progress) * travel
            body.scaleY = sample(flipTuck, at: progress)
        }

        // The eyes: their own clock, faster than the beat, so they keep moving in the gaps.
        let dartCycle = 0.86 + 0.34 * traits.phase
        let dartIndex = Int((time / dartCycle).rounded(.down))
        var dartClock = time - Double(dartIndex) * dartCycle
        if dartClock < 0 { dartClock += dartCycle }
        if dartClock <= saccadeDuration {
            let progress = dartClock / saccadeDuration
            if wrapped(dartIndex, 5) == 4 {
                // Every fifth glance is a double take: a look, a harder look the same way, then back.
                eyes.offsetX = sample(doubleTakeX, at: progress) * traits.side
                eyes.offsetY = sample(doubleTakeY, at: progress)
            } else {
                let dart = darts[wrapped(dartIndex, darts.count)]
                let distance = sample(saccadeTravel, at: progress)
                eyes.offsetX = distance * dart.x * traits.side
                eyes.offsetY = distance * dart.y
            }
        }

        // The squint: one slow cycle of its own, so it does not coincide with the beat.
        let squintCycle = 3.4 + 0.8 * traits.phase
        let squintIndex = Int((time / squintCycle).rounded(.down))
        var squintClock = time - Double(squintIndex) * squintCycle
        if squintClock < 0 { squintClock += squintCycle }
        if squintClock <= squintDuration {
            eyes.scaleY *= sample(squintLid, at: squintClock / squintDuration)
        }

        return BotAvatarPerformance(body: body, eyes: eyes)
    }

    /// The whole face at one instant: the reference's frame, with the state's stunts performed over
    /// it. This is what `BotAvatarView` draws; `frame` stays the port.
    public static func performedFrame(activity: BotAvatarActivity,
                                      traits: BotAvatarMotionTraits,
                                      at time: Double,
                                      side: Double) -> Frame {
        let reference = frame(activity: activity, traits: traits, at: time, side: side)
        return performance(activity: activity, traits: traits, at: time, side: side)
            .applied(to: reference)
    }
}
