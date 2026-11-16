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

    public init(phase: Double, eyeLoop: Int) {
        self.phase = phase
        self.eyeLoop = eyeLoop
    }

    /// From the reference's own per-identity stream (`logo-avatar/v2/<identity>`): the fourth draw
    /// is the phase, and the eye loop is `identitySeed % 4`, as `data-eye-pattern` was.
    public init(identity: String) {
        var random = BotAvatarRandom(seed: BotAvatarHash.shippedHash("logo-avatar/v2/\(identity)"))
        _ = random.next() // blink variant
        _ = random.next() // blink delay
        _ = random.next() // tempo
        phase = random.next()
        eyeLoop = BotAvatarHash.identitySeed(for: identity) % 4
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

    // MARK: - Per-activity eyes

    /// One authored frame of the eyes: where they look, and how far the lids close.
    ///
    /// The reference's *shipped shapes* carry still eyes — its `bot-character-eyes` group has no
    /// CSS animation at all. Its animated avatar (`logo-avatar-motion.ts`) is where the eye acting
    /// lives, and it is authored **per activity**: a small drift at rest, three left-to-right sweeps
    /// with a squint while reading, dips while writing, a look up while thinking, side glances while
    /// on the computer. That model is what this table reproduces; offsets are the reference's
    /// pixel units divided by the 60-unit gap between the eyes' outer edges, because
    /// `BotAvatarEyePose` translates as a fraction of the eyes' own box.
    struct EyeTrack {
        var time: Double
        var offsetX: Double
        var offsetY: Double
        var squint: Double
    }

    static func eyeTrack(for activity: BotAvatarActivity) -> (duration: Double, frames: [EyeTrack]) {
        func f(_ time: Double, _ x: Double = 0, _ y: Double = 0, _ squint: Double = 1) -> EyeTrack {
            EyeTrack(time: time, offsetX: x, offsetY: y, squint: squint)
        }
        switch activity {
        case .idle:
            // `idleX` / `idleY`: a glance away and back, once per cycle.
            return (8.0, [f(0), f(0.66), f(0.70, 0.066, -0.033), f(0.78, 0.066, -0.033), f(0.82), f(1)])
        case .reading:
            // `readingX` / `readingY` / `readingLid`: three sweeps across the page, the gaze stepping
            // down a line each time, lids held at 0.76 of their height — the "reading" that was asked
            // for. The reference reaches 20px on a 259-unit box; 20/60 of the eye box is 0.33.
            return (4.8, [
                f(0, 0, 0, 0.76), f(0.06, 0, 0, 0.76),
                f(0.24, 0.33, 0, 0.76), f(0.28, 0.33, 0, 0.76),
                f(0.34, 0, 0.083, 0.76), f(0.38, 0, 0.083, 0.76),
                f(0.54, 0.33, 0.083, 0.76), f(0.58, 0.33, 0.083, 0.76),
                f(0.64, 0, 0.167, 0.76), f(0.68, 0, 0.167, 0.76),
                f(0.84, 0.33, 0.167, 0.76), f(0.88, 0.33, 0.167, 0.76),
                f(0.96, 0, 0, 0.76), f(1, 0, 0, 0.76),
            ])
        case .writing:
            // `writingY`: the gaze dips twice per cycle, as if following a line being written.
            return (3.6, [f(0), f(0.1), f(0.18, 0, 0.05), f(0.26), f(0.56), f(0.64, 0, 0.1), f(0.72), f(1)])
        case .thinking:
            // A look up and off to the side, held — the shape of "working something out".
            return (3.2, [f(0), f(0.35, 0, -0.1), f(0.55, 0, -0.1), f(1)])
        case .computer:
            // Side glances, as if reading two windows: the largest horizontal moves in the table.
            return (2.4, [f(0, -0.2), f(0.25, -0.2), f(0.35, 0.2), f(0.6, 0.2), f(0.7, -0.05), f(1, -0.2)])
        case .working:
            // Small, quick pans: busy, and deliberately smaller than `computer` so the two states do
            // not read as the same face.
            return (2.0, [f(0, -0.08), f(0.25, 0.08), f(0.5, -0.05, 0.05), f(0.75, 0.06, -0.03), f(1, -0.08)])
        case .waiting:
            // Looking down and in: the reference's "needs attention" posture, without moving much.
            return (3.0, [f(0, 0, 0.05), f(0.5, 0, 0.08), f(1, 0, 0.05)])
        case .error:
            // The reference rests its error state; still eyes are the readable choice.
            return (1, [f(0), f(1)])
        }
    }

    /// Seconds between blinks, per activity: the busier the bot, the more often it closes its eyes.
    static func blinkInterval(for activity: BotAvatarActivity) -> Double {
        switch activity {
        case .working: return 1.15
        case .computer: return 1.6
        case .writing: return 1.9
        case .reading: return 2.4
        case .idle: return 2.7
        case .thinking: return 3.0
        case .waiting: return 3.4
        case .error: return 0
        }
    }

    /// The blink curve: shut fast, hold a moment, open slower — 160 ms in total, as the reference's
    /// `blink` track (1 → 0.06 at 50/160, hold to 70/160, back to 1).
    static func blinkFactor(activity: BotAvatarActivity, traits: BotAvatarMotionTraits,
                            at time: Double) -> Double {
        let interval = blinkInterval(for: activity)
        guard interval > 0 else { return 1 }
        let window = 0.16
        let phase = time / interval + traits.phase
        let local = (phase - phase.rounded(.down)) * interval
        guard local < window else { return 1 }
        let u = local / window
        if u < 0.31 { return 1 - (1 - 0.06) * (u / 0.31) }
        if u < 0.44 { return 0.06 }
        return 0.06 + (1 - 0.06) * ((u - 0.44) / (1 - 0.44))
    }

    /// The eyes for one instant of one activity: the authored track, squinted by its lid, closed by
    /// the blink. This is what the face draws for **every** state — the reference animates the eyes
    /// whether or not the bot is running something.
    public static func eyePose(activity: BotAvatarActivity,
                               traits: BotAvatarMotionTraits,
                               at time: Double) -> BotAvatarEyePose {
        let track = eyeTrack(for: activity)
        let span = max(track.duration, 0.001)
        var phase = time / span + traits.phase
        phase -= phase.rounded(.down)
        var pose = sampleTrack(track.frames, at: phase)
        pose.scaleY *= blinkFactor(activity: activity, traits: traits, at: time)
        return pose
    }

    static func sampleTrack(_ frames: [EyeTrack], at phase: Double) -> BotAvatarEyePose {
        guard let first = frames.first, let last = frames.last else { return .rest }
        if phase <= first.time { return BotAvatarEyePose(offsetX: first.offsetX, offsetY: first.offsetY, scaleY: first.squint) }
        if phase >= last.time { return BotAvatarEyePose(offsetX: last.offsetX, offsetY: last.offsetY, scaleY: last.squint) }
        for index in 1..<frames.count where frames[index].time >= phase {
            let from = frames[index - 1]
            let to = frames[index]
            let span = max(to.time - from.time, 0.0001)
            let u = easeInOut((phase - from.time) / span)
            return BotAvatarEyePose(offsetX: from.offsetX + (to.offsetX - from.offsetX) * u,
                                    offsetY: from.offsetY + (to.offsetY - from.offsetY) * u,
                                    scaleY: from.squint + (to.squint - from.squint) * u)
        }
        return .rest
    }
}
