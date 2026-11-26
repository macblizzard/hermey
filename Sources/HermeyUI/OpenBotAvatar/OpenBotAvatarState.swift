import Foundation

/// What a bot is doing, as the avatar's own drawing takes it.
///
/// These are the eight states the app already uses for its face — the same words, in the same
/// order, so a surface never translates between two vocabularies. The renderer does not own the
/// vocabulary (`BotAvatarActivity` in `HermesKit` does); it accepts one of these and draws it.
///
/// Every state wears the same body at the same size and the same pair of eyes; what tells them
/// apart is what each one *does* with them. `working` sweeps a band of ribbons round the body and
/// its eyes dart, `done` celebrates inside a cage of nine ribbons on three hoops, `thinking` leans
/// and looks up and away, `waiting` leans aside and glances at what it waits on, `blocked` stops and
/// stares straight back, `reading`/`computer` lean the face at a page or a screen — all over and
/// above a calm breathing pose. None of them carries a mark: a mark is drawn instead of a face, so a
/// marked state is an eyeless one, and at 24 pt a mark beside a body is mud — the motion says what
/// the state is and the eyes stay. The mark machinery is real and lives in `OpenBotAvatarMarks`, for
/// a definition of a host's own (`AvatarStateDefinition`).
///
/// Nothing here allocates or reads a clock: a pose is a pure function of (state, mood, time, seed),
/// so a frame can be reproduced and tested.
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
    /// `stateAge` is how long this state has been showing, where the surface knows: `done` celebrates
    /// from the moment it begins, so a host that animates passes it (`motion.ts` `PoseInput.stateAge`).
    /// Without it `done` runs its cycle on the clock, which is what a list row and the pet have always
    /// done — a done bot there celebrates every few seconds instead of once.
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
                     eyeOverride: OpenBotAvatarEyeOverride? = nil,
                     stateAge: Double? = nil) -> OpenBotAvatarPose {
        var pose = OpenBotAvatarPose()
        pose.mood = mood
        // Upstream's resting view: turned a little and seen a little from above, so the inferred
        // volume reads without dominating the silhouette.
        pose.yaw = OpenBotAvatarPose.restYaw
        pose.pitch = OpenBotAvatarPose.restPitch
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
            // Celebrates: a few turns inside a cage of nine ribbons on three crossing hoops, then a
            // rest, content and a little slower than idle, and after a while again, the other way
            // round. Upstream's `done` (motion.ts:455): the ribbons go round DONE_SWEEPS times while
            // the body turns a third as often, then draw back in; a cycle lasts DONE_CYCLE_S or up to
            // a seventh longer, differently for each avatar, so several done bots on a page drift
            // apart instead of turning together.
            //
            // It is idle's body at idle's size with idle's eyes — a happy bot wears the mood's arc,
            // which is the mood's channel in every state, and a neutral one draws the ordinary pill.
            rest(1.25)
            // Counted from when the state began; without an age, from the clock. Under reduced
            // motion it is at rest, past its celebration.
            let age = !reducedMotion ? max(0, stateAge ?? t) : Self.doneTurnSeconds
            let length = Self.doneCycleSeconds * (1 + 0.15 * Self.noise(seed, 31))
            let cycle = (age / length).rounded(.down)
            let since = age - cycle * length
            if since < Self.doneTurnSeconds {
                let swell = sin(.pi * since / Self.doneTurnSeconds)
                let way: Double = cycle.truncatingRemainder(dividingBy: 2) != 0 ? -1 : 1
                let sweep = Self.celebration(since) * way
                // The body turns a third as often as the ribbons go round.
                pose.yaw += Self.near(sweep / 3)
                pose.lift -= 2.2 * swell
                pose.sy += 0.04 * swell
                // All the ribbons out at full strength while the turn is quick, drawn back in as it
                // settles.
                pose.ribbons = max(0, min(1, min(since / 0.1,
                                                  (Self.doneTurnSeconds - since) / Self.doneDrawInSeconds)))
                // Nine ribbons on three hoops: the cage.
                pose.cage = 1
                // The ribbons only set off once the turn goes forward: the wind-up does not carry them.
                pose.sweep = way * max(0, Self.celebration(since))
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

    /// A state that starts part way through itself: `done` mounts past its celebration, as if it had
    /// just finished (`motion.ts:327`, the definition's `startAge`).
    public var startAge: Double? {
        self == .done ? Self.doneTurnSeconds : nil
    }

    // MARK: - The celebration

    /// Upstream's celebration timings, `motion.ts:215-222`: the turn covers the turn and the drawing
    /// in, a cycle lasts 6.2 s or up to a seventh longer per avatar, and the ribbons draw back in over
    /// the last half second.
    public static let doneTurnSeconds = 3.87
    public static let doneCycleSeconds = 6.2
    static let doneSweeps = 9
    static let doneDrawInSeconds = 0.5
    /// The fast part of the turn ends here; the rest is the slow-down that lands on nine whole turns.
    /// `motion.ts:263-264`.
    static let celebrationEndSeconds = 3.79
    static let celebrationSpeed = (Double(doneSweeps) * 2 * .pi + 0.5) / 2.4625

    /// An angle as the nearest way round to it, −π…π, so a blend never unwinds whole turns.
    /// `motion.ts:256`.
    static func near(_ angle: Double) -> Double {
        angle - 2 * .pi * (angle / (2 * .pi)).rounded()
    }

    /// How far a celebration's ribbons have gone round `t` seconds in, radians, on upstream's curve:
    /// half a radian of wind-up the other way over 0.24 s, a speed-up to a steady run, then from
    /// 2.54 s a slow-down that lands, at 3.79 s, on nine whole turns. `motion.ts:265`.
    static func celebration(_ t: Double) -> Double {
        let v = celebrationSpeed
        if t <= 0 { return 0 }
        if t < 0.24 { return -0.25 * (1 - cos(.pi * t / 0.24)) }
        if t < 0.54 { return -0.5 + (v * (t - 0.24) * (t - 0.24)) / 0.6 }
        if t < 2.54 { return -0.5 + v * (t - 0.39) }
        if t < celebrationEndSeconds {
            let landed = 1 - pow(1 - (t - 2.54) / 1.25, 4)
            return -0.5 + v * 2.15 + (1.25 * v * landed) / 4
        }
        return Double(doneSweeps) * 2 * .pi
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

    /// The calm pose of a bot with nothing to do, for a definition of a host's own: it breathes,
    /// sways, blinks and looks around. Upstream's `rest` (`motion.ts:331`), which is what `ctx.rest()`
    /// hands a definition — the same numbers the eight states sit on.
    static func resting(seed: UInt32,
                        t: Double,
                        mood: BotAvatarMood,
                        reducedMotion: Bool,
                        pace: Double) -> OpenBotAvatarPose {
        var pose = OpenBotAvatarPose()
        pose.mood = mood
        pose.yaw = OpenBotAvatarPose.restYaw
        pose.pitch = OpenBotAvatarPose.restPitch
        pose.arch = mood == .happy ? 1 : 0
        func wave(_ period: Double, _ offset: Double = 0) -> Double {
            reducedMotion ? 0 : sin(2 * .pi * t / period + offset)
        }
        pose.yaw += 0.07 * wave(6.1 * pace)
        pose.pitch += 0.04 * wave(4.7 * pace, 1)
        pose.roll = 1.6 * wave(5.3 * pace, 2)
        pose.lift = reducedMotion ? 0 : -0.45 * (1 - cos(2 * .pi * t / (3.4 * pace)))
        let breath = wave(3.4 * pace, -.pi / 2)
        pose.sy = 1 + 0.012 * breath
        pose.sx = 1 - 0.008 * breath
        if !reducedMotion {
            pose.blink = blink(seed: seed, time: t)
            let wander = wander(seed: seed, time: t)
            pose.gazeX = wander.0
            pose.gazeY = wander.1
        }
        return pose
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

/// One frame's pose, in definition units and radians. Every field is a number, or a list of marks,
/// so a pose can be interpolated, compared and drawn without any object graph.
///
/// There is deliberately no way here for one of the eight states to resize the body or to take its
/// face away: a state is a thing the bot *does*, drawn over the one silhouette and the one pair of
/// eyes every state shares. A pose that shrank the body, hid its eyes behind a mark or replaced the
/// eyes' shape is what made a thinking — and then a blocked — bot a small, faceless one in a row of
/// normal ones. `marks` exists for a definition of a host's own (upstream 0.5.0's `Pose.marks`), and
/// the eight set it to nothing: a guard in `Tests/test_open_bot_avatar.py` refuses any of them
/// touching it.
public struct OpenBotAvatarPose: Hashable, Sendable {
    /// Upstream's resting view: turned a little and seen a little from above (`motion.ts:82-83`).
    public static let restYaw = -0.30
    public static let restPitch = 0.20

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
    /// How much of the happy arc the eye wears, 0..1: 0 is the plain pill, 1 the arc. Anything in
    /// between is the morph between them (`OpenBotAvatarEyes`).
    public var arch: Double = 0
    /// How much of the flat slit the eye wears, 0..1. No built-in state sets it; it is here so a
    /// definition of a host's own can ask for the shape upstream's `waiting` used.
    public var slit: Double = 0
    /// A forward lean of the face, 0..1: it tips the eye plane and shortens the body slightly.
    public var tilt: Double = 0
    /// Presence of the ribbons circling the body, 0..1.
    public var ribbons: Double = 0
    /// Which layout the ribbons take: 0 a working turn's one hoop, 1 a celebration's cage of three.
    public var cage: Double = 0
    /// How far the turn has carried them, radians.
    public var sweep: Double = 0
    /// The marks the body gives way to, each with how far it has, 0..1: a state shows one, and a pose
    /// on the way from one state to another may show two, in the order of their ids.
    public var marks: [PoseMark] = []
    /// How lit the body's material is in this frame. A glass face reads it for its rim and its
    /// halo; a solid face has neither and ignores it.
    public var light: OpenBotAvatarLight = OpenBotAvatarLight(rim: 0.55, halo: 0.20)
}

extension OpenBotAvatarPose {

    /// The pose part way from `a` to `b`, both taken at the same moment so either side's motion keeps
    /// running. Everything is a number, the eyes' look included, so eyes morph from one shape to the
    /// next and a body gives way to a mark (and back) part by part. `motion.ts:179`.
    public static func blended(_ a: OpenBotAvatarPose, _ b: OpenBotAvatarPose, t: Double) -> OpenBotAvatarPose {
        let k = min(1, max(0, t))
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
        // The ribbons stay where the side that shows them has carried them: mixing a celebration's
        // many turns with a pose that has none would wind them back round while they fade.
        let sweep = a.ribbons > 0 && b.ribbons > 0 ? m(a.sweep, b.sweep) : a.ribbons > 0 ? a.sweep : b.sweep
        // Likewise their layout: a celebration fading out keeps its cage.
        let cage = a.ribbons > 0 && b.ribbons > 0 ? m(a.cage, b.cage) : a.ribbons > 0 ? a.cage : b.cage
        var pose = OpenBotAvatarPose()
        pose.mood = k < 0.5 ? a.mood : b.mood
        pose.yaw = m(a.yaw, b.yaw)
        pose.pitch = m(a.pitch, b.pitch)
        pose.roll = m(a.roll, b.roll)
        pose.lift = m(a.lift, b.lift)
        pose.sx = m(a.sx, b.sx)
        pose.sy = m(a.sy, b.sy)
        pose.gazeX = m(a.gazeX, b.gazeX)
        pose.gazeY = m(a.gazeY, b.gazeY)
        pose.blink = m(a.blink, b.blink)
        pose.squint = m(a.squint, b.squint)
        pose.arch = m(a.arch, b.arch)
        pose.slit = m(a.slit, b.slit)
        pose.tilt = m(a.tilt, b.tilt)
        pose.ribbons = m(a.ribbons, b.ribbons)
        pose.cage = cage
        pose.sweep = sweep
        pose.marks = OpenBotAvatarMarks.blended(a.marks, b.marks, m)
        pose.light = OpenBotAvatarLight(rim: m(a.light.rim, b.light.rim),
                                        halo: m(a.light.halo, b.light.halo),
                                        desaturate: m(a.light.desaturate, b.light.desaturate))
        return pose
    }

    /// What a definition returned, laid over the pose it started from. A definition is a host's code:
    /// a field it gives no usable value for (not a finite number) keeps the base's, so a slip in one
    /// field cannot empty the frame. `motion.ts:517`.
    public static func laid(over base: OpenBotAvatarPose, given: OpenBotAvatarPose) -> OpenBotAvatarPose {
        func number(_ value: Double, _ fallback: Double) -> Double {
            value.isFinite ? value : fallback
        }
        var pose = base
        pose.yaw = number(given.yaw, base.yaw)
        pose.pitch = number(given.pitch, base.pitch)
        pose.roll = number(given.roll, base.roll)
        pose.lift = number(given.lift, base.lift)
        pose.sx = number(given.sx, base.sx)
        pose.sy = number(given.sy, base.sy)
        pose.gazeX = number(given.gazeX, base.gazeX)
        pose.gazeY = number(given.gazeY, base.gazeY)
        pose.blink = number(given.blink, base.blink)
        pose.squint = number(given.squint, base.squint)
        pose.arch = number(given.arch, base.arch)
        pose.slit = number(given.slit, base.slit)
        pose.tilt = number(given.tilt, base.tilt)
        pose.ribbons = number(given.ribbons, base.ribbons)
        pose.cage = number(given.cage, base.cage)
        pose.sweep = number(given.sweep, base.sweep)
        pose.light = OpenBotAvatarLight(rim: number(given.light.rim, base.light.rim),
                                        halo: number(given.light.halo, base.light.halo),
                                        desaturate: number(given.light.desaturate, base.light.desaturate))
        pose.marks = OpenBotAvatarMarks.sanitised(given.marks)
        return pose
    }
}
