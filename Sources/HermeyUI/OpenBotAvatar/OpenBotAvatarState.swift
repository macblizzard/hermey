import Foundation

/// What a bot is doing, as the avatar's own drawing takes it.
///
/// These are the eight states the app already uses for its face — the same words, in the same
/// order, so a surface never translates between two vocabularies. The renderer does not own the
/// vocabulary (`BotAvatarActivity` in `HermesKit` does); it accepts one of these and draws it.
///
/// Every state wears the same body at the same size and the same pair of eyes; what tells them
/// apart is what each one *does* with them. `working` sweeps a band of ribbons round the body and
/// its eyes dart, `done` turns once, `thinking` leans and looks up and away, `waiting` leans aside
/// and glances at what it waits on, `blocked` stops and stares straight back, `reading`/`computer`
/// lean the face at a page or a screen — all over and above a calm breathing pose. There are no
/// marks: a mark is drawn instead of a face, so a marked state is an eyeless one, and at 24 pt a
/// mark beside a body is mud — the motion says what the state is and the eyes stay. Nothing here
/// allocates or reads a clock: a pose is a pure function of (state, mood, time, seed), so a frame
/// can be reproduced and tested.
public enum OpenBotAvatarState: String, CaseIterable, Hashable, Sendable {
    case idle
    case thinking
    case reading
    case working
    case computer
    case waiting
    case blocked
    case done

    /// The pose for this state. `time` is seconds on any monotonic clock; `seed` only shifts the
    /// phase, so two bots on screen never move in step.
    ///
    /// `eyeOverride` is the one way in for an eye pose decided elsewhere: `BotAvatarView` evaluates
    /// the shared face's frame once per tick (`BotAvatarMotion.performedFrame`) and hands its eyes
    /// down, so the drawn avatar blinks and looks on the schedule the shape face has always had
    /// instead of growing a second blink clock. Nil — the default, and every caller that draws this
    /// view directly — leaves the idle blinking below exactly as it was.
    ///
    /// 10 Hz is the cadence this is sampled at (the same as the pets), which is why every motion
    /// here is a slow sine or an eased fraction rather than a spring: a calm avatar at 10 Hz reads as
    /// alive, and a fast one would strobe.
    public func pose(mood: BotAvatarMood,
                     time: Double,
                     seed: UInt32,
                     reducedMotion: Bool = false,
                     eyeOverride: OpenBotAvatarEyeOverride? = nil) -> OpenBotAvatarPose {
        var pose = OpenBotAvatarPose()
        pose.mood = mood
        // Upstream's resting view: turned a little and seen a little from above, so the inferred
        // volume reads without dominating the silhouette.
        pose.yaw = -0.30
        pose.pitch = 0.20
        let phase = Double(seed % 1000) / 1000 * 10
        let t = reducedMotion ? 0 : time + phase
        let live = reducedMotion ? 0.0 : 1.0
        func wave(_ period: Double, _ offset: Double = 0) -> Double {
            reducedMotion ? 0 : sin(2 * .pi * t / period + offset)
        }

        /// The calm pose every state sits on top of: it breathes and sways.
        func rest(_ pace: Double) {
            pose.yaw += 0.07 * wave(6.1 * pace)
            pose.pitch += 0.04 * wave(4.7 * pace, 1)
            pose.roll = 1.6 * wave(5.3 * pace, 2)
            pose.lift = reducedMotion ? 0 : -0.45 * (1 - cos(2 * .pi * t / (3.4 * pace)))
            let breath = wave(3.4 * pace, -.pi / 2)
            pose.sy = 1 + 0.012 * breath
            pose.sx = 1 - 0.008 * breath
        }

        switch self {
        case .idle:
            rest(1)
            if mood == .happy {
                // Nothing to do: a happy bot hops, gently.
                let period = 2.6
                let p = reducedMotion ? 0.5 : (t.truncatingRemainder(dividingBy: period)) / period
                let air = 4 * p * (1 - p)
                pose.lift = reducedMotion ? 0 : -2.2 * air
                pose.sy = 1 - 0.02 * air * live
                pose.roll += 2.2 * wave(period * 2)
                pose.arch = 1
            }
            pose.blink = reducedMotion ? 0 : Self.blink(seed: seed, time: t)
            let wander = Self.wander(seed: seed, time: t)
            pose.gazeX = wander.0
            pose.gazeY = wander.1

        case .thinking:
            // Looks up and away while it works something out — over a body that is exactly the body
            // every other state wears. This state used to shrink to 42 % of its size and hand its
            // face to three dots, which in a row of full-size bots read as a different, smaller,
            // eyeless creature; both were the mark's doing, so the mark went. Thinking is still
            // thinking without it: a constant lean, a look up and to the side, a slower blink than
            // idle's and a 5.2 s pulse in the lift. Nothing here touches the eyes' shape, size or
            // place — `pose.squint` and `pose.arch` are how an eye is reshaped, and this one sets
            // neither, so its eyes are idle's eyes looking elsewhere.
            rest(1)
            pose.yaw += 0.12 + 0.03 * wave(7.3)
            pose.pitch += 0.08
            pose.roll = -5
            pose.lift = reducedMotion ? 0 : -0.5 * (1 - cos(2 * .pi * t / 5.2))
            pose.gazeX = 0.55
            pose.gazeY = -0.8
            pose.tilt = 0.32
            pose.blink = reducedMotion ? 0 : Self.blink(seed: seed, time: t * 0.7)

        case .reading:
            // Bent over the page: the face leans in and the eyes are down and slightly to the left.
            rest(1.1)
            pose.pitch += 0.17
            pose.roll = -3 - 0.5 * wave(6.2)
            pose.gazeX = -0.32 + 0.10 * wave(5.8)
            pose.gazeY = 0.55
            pose.tilt = 0.2
            pose.blink = reducedMotion ? 0 : Self.blink(seed: seed, time: t * 0.55)

        case .working:
            // Getting on with it: a quick bob, eyes darting over the work, and every few seconds a
            // band of ribbons sweeps once round the body.
            rest(1.3)
            let beat = wave(0.7)
            pose.pitch -= 0.05
            pose.roll = 3 + 0.6 * beat
            pose.lift += -0.3 * (0.5 + 0.5 * beat) * live
            pose.sy = 0.99 - 0.008 * beat
            pose.sx = 1.005 + 0.005 * beat
            pose.gazeX = reducedMotion ? 0.15 : Self.dart(seed: seed, time: t).0
            pose.gazeY = reducedMotion ? 0.30 : Self.dart(seed: seed, time: t).1
            pose.squint = 0.25
            let turn = (t / 3.2).truncatingRemainder(dividingBy: 1)
            // A band that eases out, sweeps, and draws back in.
            pose.ribbons = reducedMotion ? 0 : min(1, min(turn / 0.18, (1 - turn) / 0.28))
            pose.sweep = 2 * .pi * turn
            pose.blink = reducedMotion ? 0 : Self.blink(seed: seed, time: t * 1.3)

        case .computer:
            // At the machine: leans aside, eyes darting across the screen in front of it.
            rest(1.2)
            pose.yaw += 0.10
            pose.roll = 4 + 0.6 * wave(5.5)
            pose.gazeX = 0.55 + 0.3 * wave(1.9)
            pose.gazeY = 0.25 + 0.1 * wave(2.6, 1)
            pose.blink = reducedMotion ? 0 : Self.blink(seed: seed, time: t * 1.3)

        case .waiting:
            // Waits: a slower, deeper breath than idle's, a lean held to one side, and its eyes
            // turned aside at whatever it is waiting on, drifting a little on the same side, with a
            // blink that comes around more slowly than idle's. It used to flatten those eyes to
            // slits; that was the last thing in the set that replaced an eye's shape, and at 24 pt
            // a slit reads as a blink that never finished — so waiting now waits with idle's eyes
            // and its own look, which is the same trade thinking made.
            rest(0.9)
            pose.pitch += 0.04
            pose.roll = 7 + 1.2 * wave(6.4, 2)
            pose.gazeX = 0.5 + 0.15 * wave(8.2)
            pose.gazeY = 0.1
            pose.blink = reducedMotion ? 0 : Self.blink(seed: seed, time: t * 0.6)

        case .blocked:
            // Blocked: the one state a person has to notice, and it wears no mark — a mark is drawn
            // instead of the face, so the bot would stop looking like itself exactly when it has
            // news. It says it in the body instead: it stands stiller than anything else in the
            // set, looks straight back at you (idle wanders, waiting looks aside, thinking looks
            // away), does not blink at all, and rides one slow, deep pulse in the lift — deeper than
            // any other state's breathing, and drawn on every material, where a rim or a halo only
            // exists on glass.
            rest(0.6)
            pose.pitch += 0.05
            pose.gazeX = 0
            pose.gazeY = 0
            pose.blink = 0
            pose.lift = reducedMotion ? 0 : -1.15 * (1 - cos(2 * .pi * t / 2.9))

        case .done:
            // A rest, content and a little slower than idle; then one full turn with ribbons. It is
            // idle's body at idle's size with idle's eyes — a happy bot wears the mood's arc, which
            // is the mood's channel in every state, and a neutral one draws the ordinary pill.
            rest(1.25)
            let cycle = 5.6
            let since = reducedMotion ? cycle : t.truncatingRemainder(dividingBy: cycle)
            if since < 1.4 {
                let p = since / 1.4
                // Ease in, steady, ease out — one turn, arriving where it started.
                let eased = p * p * (3 - 2 * p)
                pose.yaw += 2 * .pi * eased
                pose.ribbons = min(1, min(since / 0.2, (1.4 - since) / 0.4))
                pose.sweep = 2 * .pi * eased
                pose.lift -= 1.2 * sin(.pi * p)
            }
            if mood == .happy { pose.arch = 1 }
            pose.blink = reducedMotion ? 0 : Self.blink(seed: seed, time: t * 0.8)
        }
        // The material's light rides the pose: same clock, same seed, same freeze under Reduce
        // Motion, so one frame is still a pure function of (state, mood, time, seed).
        pose.light = light(time: t, reducedMotion: reducedMotion)

        // An eye pose decided elsewhere (the shared face's own frame) supersedes the idle clock
        // above, channel for channel — one blink schedule per bot, not two that drift apart. Nil
        // leaves everything above untouched. Applied last so it wins over the material's pose too.
        if let eyeOverride {
            pose.blink = eyeOverride.blink
            pose.gazeX = eyeOverride.gazeX
            pose.gazeY = eyeOverride.gazeY
            pose.squint = eyeOverride.squint
        }
        return pose
    }

    // MARK: - Clocks

    /// One blink per ~4.2 s slot at a seeded offset, sometimes a double blink (upstream's curve).
    static func blink(seed: UInt32, time: Double) -> Double {
        let slot = 4.2, duration = 0.19
        let index = (time / slot).rounded(.down)
        var closure = 0.0
        for candidate in [index - 1, index] {
            let start = candidate * slot + 0.5 + Double(Self.noise(seed, Int(candidate) * 2)) * 2.9
            let starts = Self.noise(seed, Int(candidate) * 2 + 1) > 0.8 ? [start, start + 0.34] : [start]
            for begin in starts {
                let u = (time - begin) / duration
                if u > 0, u < 1 { closure = max(closure, sin(.pi * u)) }
            }
        }
        return closure
    }

    /// Short holds between quick saccades, centred more often than not.
    static func wander(seed: UInt32, time: Double) -> (Double, Double) {
        let slot = 1.9
        let index = (time / slot).rounded(.down)
        func target(_ k: Int) -> (Double, Double) {
            if noise(seed, 1000 + k * 3) < 0.4 { return (0, 0) }
            return ((noise(seed, 1001 + k * 3) * 2 - 1) * 0.6,
                    (noise(seed, 1002 + k * 3) * 2 - 1) * 0.35)
        }
        let from = target(Int(index) - 1), to = target(Int(index))
        let e = Self.smooth((time - index * slot) / 0.16)
        return (from.0 + (to.0 - from.0) * e, from.1 + (to.1 - from.1) * e)
    }

    /// Working: the eyes dart from one thing to the next, mostly down at the work.
    static func dart(seed: UInt32, time: Double) -> (Double, Double) {
        let slot = 0.62
        let index = (time / slot).rounded(.down)
        func target(_ k: Int) -> (Double, Double) {
            ((noise(seed, 2001 + k * 3) * 2 - 1) * 0.8, 0.1 + noise(seed, 2002 + k * 3) * 0.5)
        }
        let from = target(Int(index) - 1), to = target(Int(index))
        let e = Self.smooth((time - index * slot) / 0.12)
        return (from.0 + (to.0 - from.0) * e, from.1 + (to.1 - from.1) * e)
    }

    /// Stateless hash noise in [0, 1): the same arithmetic upstream uses, so a seed means the same
    /// phase on both sides.
    static func noise(_ seed: UInt32, _ n: Int) -> Double {
        var h = seed ^ UInt32(truncatingIfNeeded: Int32(truncatingIfNeeded: n) &* Int32(bitPattern: 0x9e37_79b1))
        h = UInt32(truncatingIfNeeded: Int64(h ^ (h >> 16)) &* 0x85eb_ca6b)
        h = UInt32(truncatingIfNeeded: Int64(h ^ (h >> 13)) &* 0xc2b2_ae35)
        h ^= h >> 16
        return Double(h) / 4_294_967_296
    }

    private static func smooth(_ u: Double) -> Double {
        let x = min(1, max(0, u))
        return x * x * (3 - 2 * x)
    }
}

/// How a bot feels. It shapes the eyes on top of any state: `happy` draws them as arcs.
public enum BotAvatarMood: String, CaseIterable, Hashable, Sendable {
    case neutral
    case happy
}

/// One frame's pose, in definition units and radians. Every field is a number so a pose can be
/// interpolated, compared and drawn without any object graph.
///
/// There is deliberately no way here to resize the body or to take its face away: a state is a
/// thing the bot *does*, drawn over the one silhouette and the one pair of eyes every state shares.
/// A pose that shrinks the body, hides its eyes behind a mark or replaces the eyes' shape is what
/// made a thinking — and then a blocked — bot a small, faceless one in a row of normal ones, and
/// `Tests/test_open_bot_avatar.py` refuses to let any of those channels come back.
public struct OpenBotAvatarPose: Hashable, Sendable {
    public var mood: BotAvatarMood = .neutral
    /// Extra view rotation on top of the resting three-quarter view.
    public var yaw: Double = 0
    public var pitch: Double = 0
    /// In-plane rotation, degrees.
    public var roll: Double = 0
    /// Vertical offset, negative is up.
    public var lift: Double = 0
    /// Squash and stretch about the base.
    public var sx: Double = 1
    public var sy: Double = 1
    /// Eye look direction, -1..1 per axis.
    public var gazeX: Double = 0
    public var gazeY: Double = 0
    /// 0 open, 1 closed.
    public var blink: Double = 0
    /// Extra lid narrowing, 0..1.
    public var squint: Double = 0
    /// 1 draws the happy arc instead of a pill (the mood's shape).
    public var arch: Double = 0
    /// A forward lean of the face, 0..1: it tips the eye plane and shortens the body slightly.
    public var tilt: Double = 0
    /// Presence of the ribbons circling the body, 0..1.
    public var ribbons: Double = 0
    /// How far the turn has carried them, radians.
    public var sweep: Double = 0
    /// How lit the body's material is in this frame. A glass face reads it for its rim and its
    /// halo; a solid face has neither and ignores it.
    public var light: OpenBotAvatarLight = OpenBotAvatarLight(rim: 0.55, halo: 0.20)
}
