import Foundation
import HermesKit

/// How far a body is moved, turned, stretched and lit at one instant.
///
/// Translations are fractions of the avatar's side, not points: the reference's keyframes were
/// authored for a 120-unit organic box, and a fraction keeps the same feel at 16 pt and at 96 pt.
public struct BotAvatarPose: Equatable, Sendable {
    public var translateX: Double
    public var translateY: Double
    /// Degrees, clockwise.
    public var rotate: Double
    public var scaleX: Double
    public var scaleY: Double
    /// Added to 1.0 and applied as a brightness filter: 0.12 is the reference's `brightness(1.12)`.
    public var brightness: Double

    public init(translateX: Double = 0,
                translateY: Double = 0,
                rotate: Double = 0,
                scaleX: Double = 1,
                scaleY: Double = 1,
                brightness: Double = 0) {
        self.translateX = translateX
        self.translateY = translateY
        self.rotate = rotate
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.brightness = brightness
    }

    /// Nothing moved: what Reduce Motion and the resting states draw.
    public static let rest = BotAvatarPose()

    public var isRest: Bool { self == .rest }
}

/// How far an eyes layer is shifted and squashed at one instant.
///
/// Offsets are fractions of the eyes' own box, which is what the reference's `translate(9%, …)`
/// means on the group it animates.
public struct BotAvatarEyePose: Equatable, Sendable {
    public var offsetX: Double
    public var offsetY: Double
    public var scaleX: Double
    public var scaleY: Double

    public init(offsetX: Double = 0, offsetY: Double = 0, scaleX: Double = 1, scaleY: Double = 1) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.scaleX = scaleX
        self.scaleY = scaleY
    }

    public static let rest = BotAvatarEyePose()
}

/// The per-identity timing the reference derives once and reuses: a phase offset for the body and
/// one of four gaze-and-blink loops for the eyes.
public struct BotAvatarMotionTraits: Hashable, Sendable {
    /// 0..<1: where in its cycle this bot's body starts, so two bots do not breathe in lockstep.
    public var phase: Double
    /// 0..3: which `rakazo-organic-eyes-loop-N` the face runs.
    public var eyeLoop: Int

    /// Which of the two authored blink schedules this face runs (`blinkVariant` three or four).
    public var blinkStarts: [Double]
    /// Where in the 24 s blink loop this face starts, in milliseconds (`blinkDelayMs`).
    public var blinkDelay: Double
    /// Which of the three tempos this face runs; it picks the periods below (`tempo`).
    public var tempo: Int
    /// Which way this face biases its glances: +1 or -1 (`side`).
    public var side: Double

    public init(phase: Double, eyeLoop: Int,
                blinkStarts: [Double] = BotAvatarMotionTraits.threeBlinkStarts,
                blinkDelay: Double = 0,
                tempo: Int = 1,
                side: Double = 1) {
        self.phase = phase
        self.eyeLoop = eyeLoop
        self.blinkStarts = blinkStarts
        self.blinkDelay = blinkDelay
        self.tempo = tempo
        self.side = side
    }

    /// The reference's two schedules: three blinks or four, at fixed points in a 24 s loop.
    public static let threeBlinkStarts: [Double] = [4100, 11500, 20000]
    public static let fourBlinkStarts: [Double] = [3200, 8900, 14200, 21100]
    /// Every track completes whole cycles in this interval (`LOGO_AVATAR_LOOP_MS`).
    public static let loopMilliseconds: Double = 24_000

    /// From the reference's own per-identity stream (`logo-avatar/v2/<identity>`): the fourth draw
    /// is the phase, and the eye loop is `identitySeed % 4`, as `data-eye-pattern` was.
    public init(identity: String) {
        var random = BotAvatarRandom(seed: BotAvatarHash.shippedHash("logo-avatar/v2/\(identity)"))
        let variant = random.next()
        let delay = random.next()
        let tempoDraw = random.next()
        phase = random.next()
        let sideDraw = random.next()
        eyeLoop = BotAvatarHash.identitySeed(for: identity) % 4
        // The reference draws in this order: variant, delay, tempo, phase, side, energy.
        blinkStarts = variant < 0.5 ? Self.threeBlinkStarts : Self.fourBlinkStarts
        blinkDelay = -((delay * Self.loopMilliseconds * 1000).rounded() / 1000)
        tempo = Int((tempoDraw * 3).rounded(.down)) % 3
        side = sideDraw > 0.5 ? 1 : -1
    }
}

/// The reference's keyframes, as data.
///
/// Each activity runs one of the CSS animations from `styles.css`, at the same cycle length:
///
/// | activity | reference keyframes | cycle |
/// | --- | --- | --- |
/// | idle | `rakazo-organic-float` | 1.8 s |
/// | reading | `rakazo-organic-sway` | 1.6 s |
/// | writing | `rakazo-organic-squash` | 1.35 s |
/// | thinking | `rakazo-organic-pulse` | 1.1 s |
/// | computer | `rakazo-organic-turn` | 2.4 s |
/// | working | `rakazo-organic-ring` + the spinning working ring | 1.35 s (ring 1.2 s) |
/// | waiting | `rakazo-avatar-breathe` + the working ring | 1.6 s |
/// | error | none: it rests | — |
///
/// Two of those mappings are a decision, not a transcription, and are called out here rather than
/// hidden: the reference draws the shipped *shapes* statically and only animates its organic bodies
/// and the picture avatar, so `idle` borrows the float that family 0 of the organic set uses, and
/// `waiting` borrows `rakazo-avatar-breathe`, the scale-and-brighten the reference plays on a busy
/// picture, because waiting's only other cue in the reference is the ring and "draws attention" has
/// to look different from working. `error` rests, as the reference rests it.
///
/// All of them use the CSS `ease-in-out` timing function, which SwiftUI has no name for, so
/// `easeInOut` solves the real cubic-bezier(0.42, 0, 0.58, 1) rather than substituting a curve.
public enum BotAvatarMotion {
    /// Thirty frames a second: the reference's CSS animations are compositor work at whatever the
    /// display runs, but a `TimelineView` that redraws eight paths at 120 Hz on a phone is a
    /// battery bug, and the same beat the old spinner used.
    public static let frameInterval: Double = 1.0 / 30.0

    /// The beat a face draws at, per activity.
    ///
    /// The reference animates idle too (breathe, a glance, a blink), and that life is the point —
    /// but a web page gets it from the compositor while a SwiftUI `TimelineView` redraws the whole
    /// subtree, so the same motion costs ~19 pp of a core on this Mac. Idle keeps its motion at a
    /// third of the beat: a 0.5 % breath and a 0.16 s blink survive 10 Hz, and twenty list rows stop
    /// costing what one working face should.
    public static func frameInterval(for activity: BotAvatarActivity) -> Double {
        activity == .idle ? 1.0 / 10.0 : frameInterval
    }

    /// The working ring's stroke turn, `rakazo-avatar-spin`.
    public static let workingRingDuration: Double = 1.2

    /// The smallest side that may animate, as in the reference's `canMove = motion && size >= 24`:
    /// below this a moving face is a twitch in a list, not a sign of life.
    public static let minimumAnimatingSize: Double = 24

    // MARK: - The app's own switch

    /// The key Settings writes and every face reads. Still spelled the old way so a device that
    /// already answered it keeps its answer.
    public static let defaultsKey = "animateBotFaces"

    /// The app's own answer, or `nil` if it has never been given one.
    ///
    /// Motion is a courtesy, and the person using the app outranks the system's default — but only
    /// once they have said so. `BotAvatarView` reads this through `@AppStorage`, so flipping the
    /// switch redraws every face without a relaunch.
    public static var appChoice: Bool? {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool
    }

    /// Writes the once-and-for-all answer on first launch, taken from the system.
    ///
    /// Without this the switch in Settings showed "on" (its default) while the faces followed the
    /// system's Reduce Motion, so an owner with Reduce Motion on saw a switch that said one thing
    /// and an app that did another.
    public static func seedIfNeeded(reduceMotion: Bool) {
        guard appChoice == nil else { return }
        UserDefaults.standard.set(!reduceMotion, forKey: defaultsKey)
    }

    /// Whether this avatar should move at all.
    ///
    /// `minimumSize` is the caller's floor, not a global rule: a 16 pt face in a status row is the
    /// only thing on screen and is worth animating, while the same 16 pt in a long list is not.
    /// It defaults to the house floor so a caller that does not think about it gets the cheap
    /// answer.
    public static func allows(activity: BotAvatarActivity,
                              reduceMotion: Bool,
                              animates: Bool = true,
                              size: Double,
                              minimumSize: Double = minimumAnimatingSize) -> Bool {
        guard animates, !reduceMotion, activity.isAnimated else { return false }
        return size >= minimumSize
    }

    /// The cycle length for an activity, in seconds. Zero for the rest.
    public static func duration(of activity: BotAvatarActivity) -> Double {
        switch activity {
        case .idle: return 1.8
        case .reading: return 1.6
        case .writing: return 1.35
        case .thinking: return 1.1
        case .computer: return 2.4
        case .working: return 1.35
        case .waiting: return 1.6
        case .error: return 0
        }
    }

    /// The body at a wall-clock instant.
    public static func bodyPose(activity: BotAvatarActivity,
                                at time: Double,
                                traits: BotAvatarMotionTraits) -> BotAvatarPose {
        let duration = duration(of: activity)
        let frames = keyframes(for: activity)
        guard duration > 0, frames.count > 1 else { return .rest }
        return sample(frames, time: time, duration: duration, phase: traits.phase)
    }

    /// The eyes at a wall-clock instant, on this identity's loop.
    public static func eyePose(traits: BotAvatarMotionTraits, at time: Double) -> BotAvatarEyePose {
        eyePose(loop: traits.eyeLoop, at: time)
    }

    public static func eyePose(loop: Int, at time: Double) -> BotAvatarEyePose {
        let loops = eyeLoops
        guard !loops.isEmpty else { return .rest }
        let index = ((loop % loops.count) + loops.count) % loops.count
        let program = loops[index]
        return sampleEyes(program.frames, time: time, duration: program.duration, phase: program.phase)
    }

    // MARK: - Body keyframes

    struct BodyFrame {
        var time: Double
        var pose: BotAvatarPose
    }

    static func keyframes(for activity: BotAvatarActivity) -> [BodyFrame] {
        // The reference's px offsets against its 120-unit organic view box.
        let unit = 1.0 / 120.0

        switch activity {
        case .idle: // rakazo-organic-float 1.8s
            return [
                BodyFrame(time: 0, pose: BotAvatarPose(translateY: 2 * unit, scaleX: 1.02)),
                BodyFrame(time: 0.5, pose: BotAvatarPose(translateY: -3 * unit, scaleX: 0.98)),
                BodyFrame(time: 1, pose: BotAvatarPose(translateY: 2 * unit, scaleX: 1.02)),
            ]
        case .reading: // rakazo-organic-sway 1.6s
            return [
                BodyFrame(time: 0, pose: BotAvatarPose(translateX: -1 * unit, rotate: -3)),
                BodyFrame(time: 0.5, pose: BotAvatarPose(translateX: 1 * unit, rotate: 3)),
                BodyFrame(time: 1, pose: BotAvatarPose(translateX: -1 * unit, rotate: -3)),
            ]
        case .writing: // rakazo-organic-squash 1.35s
            return [
                BodyFrame(time: 0, pose: BotAvatarPose(scaleX: 1.04, scaleY: 0.96)),
                BodyFrame(time: 0.5, pose: BotAvatarPose(scaleX: 0.96, scaleY: 1.04)),
                BodyFrame(time: 1, pose: BotAvatarPose(scaleX: 1.04, scaleY: 0.96)),
            ]
        case .thinking: // rakazo-organic-pulse 1.1s
            return [
                BodyFrame(time: 0, pose: BotAvatarPose(scaleX: 0.96, scaleY: 0.96)),
                BodyFrame(time: 0.45, pose: BotAvatarPose(scaleX: 1.06, scaleY: 1.06)),
                BodyFrame(time: 1, pose: BotAvatarPose(scaleX: 0.96, scaleY: 0.96)),
            ]
        case .computer: // rakazo-organic-turn 2.4s
            return [
                BodyFrame(time: 0, pose: BotAvatarPose(rotate: -4, scaleX: 0.98, scaleY: 0.98)),
                BodyFrame(time: 0.5, pose: BotAvatarPose(rotate: 4, scaleX: 1.04, scaleY: 1.04)),
                BodyFrame(time: 1, pose: BotAvatarPose(rotate: -4, scaleX: 0.98, scaleY: 0.98)),
            ]
        case .working: // rakazo-organic-ring 1.35s
            return [
                BodyFrame(time: 0, pose: BotAvatarPose(rotate: -4)),
                BodyFrame(time: 0.35, pose: BotAvatarPose(rotate: 5)),
                BodyFrame(time: 0.65, pose: BotAvatarPose(rotate: -3)),
                BodyFrame(time: 1, pose: BotAvatarPose(rotate: -4)),
            ]
        case .waiting: // rakazo-avatar-breathe 1.6s
            return [
                BodyFrame(time: 0, pose: BotAvatarPose(scaleX: 1, scaleY: 1, brightness: 0)),
                BodyFrame(time: 0.5, pose: BotAvatarPose(scaleX: 1.07, scaleY: 1.07, brightness: 0.12)),
                BodyFrame(time: 1, pose: BotAvatarPose(scaleX: 1, scaleY: 1, brightness: 0)),
            ]
        case .error:
            return [BodyFrame(time: 0, pose: .rest)]
        }
    }

    // MARK: - Eyes keyframes

    struct EyeProgram {
        var duration: Double
        /// Where the loop starts, from the reference's negative animation delays.
        var phase: Double
        var frames: [EyeFrame]
    }

    struct EyeFrame {
        var time: Double
        var pose: BotAvatarEyePose
    }

    /// `rakazo-organic-eyes-loop-0..3`, at their own cycle lengths and starting phases.
    static let eyeLoops: [EyeProgram] = [
        EyeProgram(duration: 6.6, phase: 0, frames: [
            EyeFrame(time: 0, pose: BotAvatarEyePose(offsetX: -0.09, offsetY: 0.01, scaleY: 0.94)),
            EyeFrame(time: 0.18, pose: BotAvatarEyePose(offsetX: 0.09, offsetY: -0.02, scaleY: 1.04)),
            EyeFrame(time: 0.34, pose: BotAvatarEyePose(offsetX: 0, offsetY: -0.08, scaleX: 1.08, scaleY: 1.08)),
            EyeFrame(time: 0.48, pose: BotAvatarEyePose(scaleX: 1.12, scaleY: 0.82)),
            EyeFrame(time: 0.51, pose: BotAvatarEyePose(scaleX: 1.05, scaleY: 0.08)),
            EyeFrame(time: 0.54, pose: BotAvatarEyePose(scaleX: 1.12, scaleY: 0.90)),
            EyeFrame(time: 0.72, pose: BotAvatarEyePose(offsetX: -0.05, offsetY: 0.07, scaleY: 0.90)),
            EyeFrame(time: 0.86, pose: BotAvatarEyePose(offsetX: 0.07, offsetY: 0.03)),
            EyeFrame(time: 1, pose: BotAvatarEyePose(offsetX: -0.09, offsetY: 0.01, scaleY: 0.94)),
        ]),
        EyeProgram(duration: 7.2, phase: 1.4 / 7.2, frames: [
            EyeFrame(time: 0, pose: BotAvatarEyePose(offsetY: -0.08, scaleX: 1.06, scaleY: 1.06)),
            EyeFrame(time: 0.16, pose: BotAvatarEyePose(offsetX: 0.08, offsetY: 0.02)),
            EyeFrame(time: 0.31, pose: BotAvatarEyePose(offsetY: 0.08, scaleY: 0.90)),
            EyeFrame(time: 0.46, pose: BotAvatarEyePose(offsetX: -0.08, offsetY: 0.02)),
            EyeFrame(time: 0.61, pose: BotAvatarEyePose(scaleX: 0.88, scaleY: 1.10)),
            EyeFrame(time: 0.76, pose: BotAvatarEyePose(offsetY: -0.07, scaleY: 1.08)),
            EyeFrame(time: 0.88, pose: BotAvatarEyePose(offsetY: 0.06, scaleX: 1.08, scaleY: 0.86)),
            EyeFrame(time: 1, pose: BotAvatarEyePose(offsetY: -0.08, scaleX: 1.06, scaleY: 1.06)),
        ]),
        EyeProgram(duration: 6.1, phase: 3.2 / 6.1, frames: [
            EyeFrame(time: 0, pose: BotAvatarEyePose(scaleX: 0.90, scaleY: 1.08)),
            EyeFrame(time: 0.20, pose: BotAvatarEyePose(scaleX: 1.14, scaleY: 0.84)),
            EyeFrame(time: 0.24, pose: BotAvatarEyePose(scaleX: 1.08, scaleY: 0.08)),
            EyeFrame(time: 0.28, pose: BotAvatarEyePose(scaleX: 1.02, scaleY: 1.02)),
            EyeFrame(time: 0.45, pose: BotAvatarEyePose(offsetX: -0.09, offsetY: -0.03, scaleY: 0.94)),
            EyeFrame(time: 0.62, pose: BotAvatarEyePose(offsetX: 0.09, offsetY: 0.02, scaleY: 1.05)),
            EyeFrame(time: 0.80, pose: BotAvatarEyePose(offsetY: -0.08, scaleX: 1.06, scaleY: 1.06)),
            EyeFrame(time: 1, pose: BotAvatarEyePose(scaleX: 0.90, scaleY: 1.08)),
        ]),
        EyeProgram(duration: 7.8, phase: 2.1 / 7.8, frames: [
            EyeFrame(time: 0, pose: BotAvatarEyePose(offsetY: 0.07, scaleY: 0.90)),
            EyeFrame(time: 0.14, pose: BotAvatarEyePose(offsetY: -0.09, scaleY: 1.08)),
            EyeFrame(time: 0.30, pose: BotAvatarEyePose(offsetX: 0.08, offsetY: -0.02)),
            EyeFrame(time: 0.47, pose: BotAvatarEyePose(offsetX: -0.08, offsetY: 0.03, scaleY: 0.94)),
            EyeFrame(time: 0.63, pose: BotAvatarEyePose(scaleX: 1.12, scaleY: 0.82)),
            EyeFrame(time: 0.78, pose: BotAvatarEyePose(offsetY: -0.07, scaleX: 0.90, scaleY: 1.08)),
            EyeFrame(time: 0.91, pose: BotAvatarEyePose(offsetY: 0.05, scaleX: 1.06, scaleY: 0.90)),
            EyeFrame(time: 1, pose: BotAvatarEyePose(offsetY: 0.07, scaleY: 0.90)),
        ]),
    ]

    // MARK: - Sampling

    static func sample(_ frames: [BodyFrame],
                       time: Double,
                       duration: Double,
                       phase: Double) -> BotAvatarPose {
        var t = time / duration + phase
        t -= t.rounded(.down)
        guard let index = frames.lastIndex(where: { $0.time <= t }) else {
            return frames.first?.pose ?? .rest
        }
        let from = frames[index]
        let to = index + 1 < frames.count ? frames[index + 1] : frames[0]
        let span = to.time - from.time
        let local = span > 0 ? (t - from.time) / span : 1
        let eased = easeInOut(min(max(local, 0), 1))
        return from.pose.lerp(to.pose, eased)
    }

    static func sampleEyes(_ frames: [EyeFrame],
                           time: Double,
                           duration: Double,
                           phase: Double) -> BotAvatarEyePose {
        var t = time / duration + phase
        t -= t.rounded(.down)
        guard let index = frames.lastIndex(where: { $0.time <= t }) else {
            return frames.first?.pose ?? .rest
        }
        let from = frames[index]
        let to = index + 1 < frames.count ? frames[index + 1] : frames[0]
        let span = to.time - from.time
        let local = span > 0 ? (t - from.time) / span : 1
        let eased = easeInOut(min(max(local, 0), 1))
        return BotAvatarEyePose(offsetX: from.pose.offsetX + (to.pose.offsetX - from.pose.offsetX) * eased,
                                offsetY: from.pose.offsetY + (to.pose.offsetY - from.pose.offsetY) * eased,
                                scaleX: from.pose.scaleX + (to.pose.scaleX - from.pose.scaleX) * eased,
                                scaleY: from.pose.scaleY + (to.pose.scaleY - from.pose.scaleY) * eased)
    }

    /// CSS `cubic-bezier(0.42, 0, 0.58, 1)`, solved rather than approximated.
    ///
    /// `u` is the fraction of the segment's time; the value returned is the fraction of the segment's
    /// distance. Bisection, because the curve is monotone in x and twelve steps is a quarter of a
    /// pixel at any size this draws.
    public static func easeInOut(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        guard x > 0, x < 1 else { return x }
        let x1 = 0.42, y1 = 0.0, x2 = 0.58, y2 = 1.0
        func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let mt = 1 - t
            return 3 * mt * mt * t * a + 3 * mt * t * t * b + t * t * t
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<16 {
            let mid = (low + high) / 2
            if bezier(mid, x1, x2) < x { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, y1, y2)
    }
    // MARK: - The reference's own motion model

    /// Where each activity's clock lives, in seconds (`traits.periods`).
    public static func period(for activity: BotAvatarActivity, tempo: Int) -> Double {
        let slow = [4.0, 4.8, 6.0][min(max(tempo, 0), 2)]
        switch activity {
        case .idle: return 24.0
        case .working, .reading, .waiting, .error: return slow
        case .writing: return [1.2, 1.5, 2.0][min(max(tempo, 0), 2)]
        case .thinking, .computer: return 6.0
        }
    }

    /// One instant of a face: what the body does, and where the eyes and lids are.
    public struct Frame: Equatable, Sendable {
        public var body: BotAvatarPose
        public var eyes: BotAvatarEyePose
        public init(body: BotAvatarPose = .rest, eyes: BotAvatarEyePose = .rest) {
            self.body = body
            self.eyes = eyes
        }
        public static let rest = Frame()
    }

    // The reference's `LOGO_AVATAR_MOTION_TRACKS`, keyframes and all. Positions are in its 259-unit
    // view box (the eyes' outer 60-unit box for the eye tracks); `sample(_:at:)` returns them
    // unchanged so the numbers here can be read against the source.
    static let blinkTrack: [(Double, Double)] = [(0, 1), (50.0 / 160, 0.06), (70.0 / 160, 0.06), (1, 1)]
    static let breatheTrack: [(Double, Double)] = [(0, 1), (0.5, 1.005), (1, 1)]
    static let idleXTrack: [(Double, Double)] = [(0, 0), (0.66, 0), (0.70, 4), (0.78, 4), (0.82, 0), (1, 0)]
    static let idleYTrack: [(Double, Double)] = [(0, 0), (0.66, 0), (0.70, -2), (0.78, -2), (0.82, 0), (1, 0)]
    static let readingXTrack: [(Double, Double)] = [
        (0, 0), (0.06, 0), (0.24, 20), (0.28, 20), (0.34, 0), (0.38, 0),
        (0.54, 20), (0.58, 20), (0.64, 0), (0.68, 0), (0.84, 20), (0.88, 20), (0.96, 0), (1, 0),
    ]
    static let readingYTrack: [(Double, Double)] = [(0, 0), (0.28, 0), (0.34, 5), (0.58, 5), (0.64, 10), (0.88, 10), (0.96, 0), (1, 0)]
    static let readingLidTrack: [(Double, Double)] = [(0, 0.76), (0.88, 0.76), (0.92, 0.06), (0.94, 0.06), (0.98, 0.76), (1, 0.76)]
    static let writingYTrack: [(Double, Double)] = [(0, 0), (0.1, 0), (0.18, 3), (0.26, 0), (0.56, 0), (0.64, 6), (0.74, 0), (1, 0)]
    static let bodyYTrack: [(Double, Double)] = [(0, 0), (0.1, 0), (0.18, 0.9), (0.26, 0), (0.56, 0), (0.64, 1.4), (0.74, 0), (1, 0)]
    static let thinkingXTrack: [(Double, Double)] = [(0, 0), (0.08, 0), (0.24, -9), (0.4, -9), (0.56, -5), (0.65, -5), (0.82, 0), (0.9, 0), (1, 0)]
    static let thinkingYTrack: [(Double, Double)] = [(0, -2), (0.08, -2), (0.24, -8), (0.4, -8), (0.56, -11), (0.65, -11), (0.82, -3), (0.9, -3), (1, -2)]
    static let thinkingLidTrack: [(Double, Double)] = [(0, 1), (0.08, 1), (0.24, 0.8), (0.4, 0.8), (0.56, 0.68), (0.65, 0.68), (0.82, 0.9), (0.9, 0.9), (1, 1)]
    static let computerXTrack: [(Double, Double)] = [(0, -10), (0.08, -10), (0.18, 10), (0.34, 10), (0.48, -8), (0.76, -8), (0.92, -10), (1, -10)]
    static let computerYTrack: [(Double, Double)] = [(0, -3), (0.34, -3), (0.48, 6), (0.76, 6), (0.92, -3), (1, -3)]

    /// The eyes' outer edges sit 60 units apart in the 259-unit box, and `BotAvatarEyePose`
    /// translates as a fraction of the eyes' own box — so the reference's units divide by 60.
    static let eyeUnits = 1.0 / 60.0
    /// Body translations are a fraction of the face's side, out of the same 259-unit box.
    static let bodyUnits = 1.0 / 259.0

    static func phase(_ elapsed: Double, delay: Double, period: Double) -> Double {
        guard period > 0 else { return 0 }
        let wrapped = (elapsed - delay).truncatingRemainder(dividingBy: period)
        return (wrapped < 0 ? wrapped + period : wrapped) / period
    }

    /// The reference's sampler: hold flat between equal values, otherwise ease across the span.
    static func sample(_ track: [(Double, Double)], at progress: Double, blink: Bool = false) -> Double {
        guard let first = track.first, let last = track.last else { return 0 }
        if progress <= first.0 { return first.1 }
        for index in 1..<track.count {
            let left = track[index - 1]
            let right = track[index]
            if progress > right.0 { continue }
            if left.1 == right.1 { return left.1 }
            let amount = (progress - left.0) / max(right.0 - left.0, 0.0001)
            // The reference uses a slightly sharper curve for a blink (0.42/0.58) than for a glide.
            let eased = blink ? easeInOut(amount) : easeInOut(amount)
            return left.1 + (right.1 - left.1) * eased
        }
        return last.1
    }

    /// Whether this state wears the "needs attention" lid rather than blinking (`waiting`).
    static func needsAttention(_ activity: BotAvatarActivity) -> Bool {
        activity == .waiting
    }

    /// The whole face at one instant, evaluated exactly as `logoAvatarFrame` does.
    public static func frame(activity: BotAvatarActivity,
                             traits: BotAvatarMotionTraits,
                             at time: Double) -> Frame {
        var eyeX = 0.0
        var eyeY = 0.0
        var lid = 1.0
        var blink = 1.0
        var bodyY = 0.0
        var bodyScale = 1.0

        // The resting posture each state starts from, before any track moves it.
        switch activity {
        case .reading: eyeX = -10; eyeY = -5; lid = 0.76
        case .writing: eyeY = 10; lid = 0.62
        case .thinking: eyeX = -3 * traits.side; eyeY = -4; lid = 0.8
        case .computer: lid = 1.12
        case .waiting: lid = 0.9
        case .error: lid = 0.68
        case .idle, .working: break
        }

        // Blinks: scheduled inside a 24 s loop, only in states that are alive and not waiting.
        if !needsAttention(activity), activity != .error {
            let elapsed = (time * 1000) - traits.blinkDelay
            let loop = BotAvatarMotionTraits.loopMilliseconds
            var local = elapsed.truncatingRemainder(dividingBy: loop)
            if local < 0 { local += loop }
            for start in traits.blinkStarts where local >= start && local <= start + 160 {
                blink = sample(blinkTrack, at: (local - start) / 160, blink: true)
                break
            }
        }

        let period = period(for: activity, tempo: traits.tempo)
        let delay = -(period * traits.phase)
        let p = phase(time, delay: delay, period: period)

        switch activity {
        case .idle, .working:
            bodyScale = sample(breatheTrack, at: p)
            if activity == .idle {
                eyeX = sample(idleXTrack, at: p) * traits.side
                eyeY = sample(idleYTrack, at: p)
            }
        case .reading:
            eyeX += sample(readingXTrack, at: p)
            eyeY += sample(readingYTrack, at: p)
            lid = sample(readingLidTrack, at: p)
        case .writing:
            eyeY += sample(writingYTrack, at: p)
            bodyY = sample(bodyYTrack, at: p)
        case .thinking:
            eyeX += sample(thinkingXTrack, at: p) * traits.side
            eyeY += sample(thinkingYTrack, at: p)
            lid = sample(thinkingLidTrack, at: p)
        case .computer:
            eyeX = sample(computerXTrack, at: p)
            eyeY = sample(computerYTrack, at: p)
        case .waiting, .error:
            break
        }

        return Frame(
            body: BotAvatarPose(translateY: bodyY * bodyUnits, scaleX: bodyScale, scaleY: bodyScale),
            eyes: BotAvatarEyePose(offsetX: eyeX * eyeUnits,
                                   offsetY: eyeY * eyeUnits,
                                   scaleY: lid * blink)
        )
    }

    /// The eyes alone, for callers that draw a body of their own.
    public static func eyePose(activity: BotAvatarActivity,
                               traits: BotAvatarMotionTraits,
                               at time: Double) -> BotAvatarEyePose {
        frame(activity: activity, traits: traits, at: time).eyes
    }

    /// The body alone, as the reference's breathe-and-bob.
    public static func referenceBody(activity: BotAvatarActivity,
                                     traits: BotAvatarMotionTraits,
                                     at time: Double) -> BotAvatarPose {
        frame(activity: activity, traits: traits, at: time).body
    }
}


extension BotAvatarPose {
    /// Interpolate towards another pose. Translation, rotation, scale and brightness all travel
    /// linearly once the timing function has been applied, which is what the CSS keyframes do
    /// between two stops of the same kind.
    func lerp(_ other: BotAvatarPose, _ t: Double) -> BotAvatarPose {
        BotAvatarPose(translateX: translateX + (other.translateX - translateX) * t,
                      translateY: translateY + (other.translateY - translateY) * t,
                      rotate: rotate + (other.rotate - rotate) * t,
                      scaleX: scaleX + (other.scaleX - scaleX) * t,
                      scaleY: scaleY + (other.scaleY - scaleY) * t,
                      brightness: brightness + (other.brightness - brightness) * t)
    }
}
