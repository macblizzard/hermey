import Foundation

/// A state of a host's own, and the easing between states — upstream 0.5.0's `stateDefinition`,
/// `AvatarStateDefinition` and `StateContext` (`packages/core/src/motion.ts`).
///
/// `state` takes either one of our eight names or a definition: an `id` and a `pose` that says what
/// differs from the resting pose. It works wherever a state does — the view, the renderer and the
/// animator all see an `OpenBotAvatarStateChoice` — and two definitions with one `id` are the same
/// state, so changing between them is not a change of state and nothing eases.
///
/// ```swift
/// let pondering = AvatarStateDefinition(id: "pondering") { ctx in
///     var pose = ctx.rest()          // the calm pose it starts from
///     pose.roll = -4 * ctx.wave(3)   // … then only what differs
///     pose.gazeY = -0.7
///     return pose
/// }
/// let view = OpenBotAvatarView(definition: bot, state: .init(pondering), size: 32)
/// ```
///
/// A definition is experimental in upstream's sense: it is written against `OpenBotAvatarPose` and
/// `StateContext`, the renderer's own model of a pose, whose fields may still be renamed in a minor
/// release. The eight names are stable.

/// What a state works its pose out from. `motion.ts:276`.
public struct StateContext {
    /// The avatar's own seed, for noise that differs from one avatar to the next.
    public var seed: UInt32
    /// The animation clock as given, seconds.
    public var time: Double
    /// The clock offset per avatar, so several on a page do not move in lockstep; 0 under reduced motion.
    public var t: Double
    /// Seconds since the state began, where the host gave it.
    public var stateAge: Double?
    public var mood: BotAvatarMood
    public var reducedMotion: Bool
    /// 1, or 0 under reduced motion: a factor for motion that should stop.
    public var live: Double
    /// How much of its own turning the body keeps: less while it attends to a look target.
    public var sway: Double
    /// A sine of this period (seconds) on the clock; 0 under reduced motion.
    public var wave: (Double, Double) -> Double
    /// The pose a state starts from: the resting view, eyes open and shaped by the mood, no ribbons
    /// or marks.
    public var base: OpenBotAvatarPose
    /// The calm pose of a bot with nothing to do, for a state that keeps the body: it breathes, sways,
    /// blinks and looks around. `pace` stretches its periods (`done` rests at 1.25).
    public var rest: (Double) -> OpenBotAvatarPose
}

/// A state: what the bot does while it is in it, as a pose for each moment.
public struct AvatarStateDefinition: @unchecked Sendable {
    /// Names the state. Two definitions with one id are the same state.
    public let id: String
    /// The age the state has when an avatar mounts in it, seconds (default 0: it starts afresh).
    /// `done` mounts past its celebration, as if it had just finished.
    public let startAge: Double?
    /// The pose at one moment: the calm pose it starts from — `ctx.base`, or `ctx.rest()` to breathe —
    /// with only what differs written over it. A pure function of the context, so a frame can be drawn
    /// again exactly; under reduced motion it returns a pose that holds still.
    public let pose: @Sendable (StateContext) -> OpenBotAvatarPose

    public init(id: String,
                startAge: Double? = nil,
                pose: @escaping @Sendable (StateContext) -> OpenBotAvatarPose) {
        self.id = id
        self.startAge = startAge
        self.pose = pose
    }
}

/// Two definitions with one id are the same state: the closure is host code and cannot be compared,
/// so the id (and the age it starts at) is what equality and hashing read.
extension AvatarStateDefinition: Hashable {
    public static func == (left: AvatarStateDefinition, right: AvatarStateDefinition) -> Bool {
        left.id == right.id && left.startAge == right.startAge
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(startAge)
    }
}

// MARK: - The definitions behind the eight names

public enum OpenBotAvatarStates {

    /// The definition of a state by name: one of the eight, or the host's own as it is.
    /// `motion.ts:492`.
    public static func stateDefinition(named state: OpenBotAvatarState) -> AvatarStateDefinition {
        AvatarStateDefinition(id: state.rawValue, startAge: state.startAge) { context in
            state.pose(mood: context.mood,
                       time: context.time,
                       seed: context.seed,
                       reducedMotion: context.reducedMotion,
                       stateAge: context.stateAge)
        }
    }

    /// What names a state: two states with one id are the same state. `motion.ts:497`.
    public static func stateId(_ choice: OpenBotAvatarStateChoice) -> String { choice.id }
}

// MARK: - What a surface passes as `state`

/// What a bot is doing: one of our eight names, or a definition of the host's own.
///
/// This is the type `OpenBotAvatarView` takes as `state`, so a host can add a state without a new case
/// in `OpenBotAvatarState` — upstream's point in 0.5.0. The eight names keep their dot shorthand
/// (`.thinking`), because they are static members here too, and they reach the same drawing code the
/// enum always ran.
public enum OpenBotAvatarStateChoice: Hashable, Sendable {
    case named(OpenBotAvatarState)
    case defined(AvatarStateDefinition)

    public init(_ state: OpenBotAvatarState) { self = .named(state) }
    public init(_ definition: AvatarStateDefinition) { self = .defined(definition) }

    public static let idle = OpenBotAvatarStateChoice(.idle)
    public static let thinking = OpenBotAvatarStateChoice(.thinking)
    public static let reading = OpenBotAvatarStateChoice(.reading)
    public static let working = OpenBotAvatarStateChoice(.working)
    public static let computer = OpenBotAvatarStateChoice(.computer)
    public static let waiting = OpenBotAvatarStateChoice(.waiting)
    public static let blocked = OpenBotAvatarStateChoice(.blocked)
    public static let done = OpenBotAvatarStateChoice(.done)

    /// What names this state: two states with one id are the same state.
    public var id: String {
        switch self {
        case .named(let state): return state.rawValue
        case .defined(let definition): return definition.id
        }
    }

    /// The built-in state, when this is one.
    public var namedState: OpenBotAvatarState? {
        if case .named(let state) = self { return state }
        return nil
    }

    /// The definition behind this state, built-in or the host's own.
    public var definition: AvatarStateDefinition {
        switch self {
        case .named(let state): return OpenBotAvatarStates.stateDefinition(named: state)
        case .defined(let definition): return definition
        }
    }

    /// The age this state has when an avatar mounts in it.
    public var startAge: Double { definition.startAge ?? 0 }

    /// The pose for this state, with what has to be eased in from (`blend`) applied over it.
    ///
    /// A built-in state with nothing to ease takes the enum's own drawing, unchanged: that is how the
    /// eight keep drawing exactly what they drew before custom states arrived.
    public func pose(mood: BotAvatarMood,
                     time: Double,
                     seed: UInt32,
                     reducedMotion: Bool = false,
                     eyeOverride: OpenBotAvatarEyeOverride? = nil,
                     stateAge: Double? = nil,
                     blend: OpenBotAvatarBlend? = nil) -> OpenBotAvatarPose {
        let easing = (blend?.t ?? 1) < 1
        if case .named(let state) = self, !easing {
            return state.pose(mood: mood, time: time, seed: seed, reducedMotion: reducedMotion,
                              eyeOverride: eyeOverride, stateAge: stateAge)
        }
        var pose = statePose(mood: mood, time: time, seed: seed, reducedMotion: reducedMotion,
                             stateAge: stateAge)
        if easing, let blend {
            // The chain reads oldest first: what was on screen before, how far the change into each
            // had got when the next one interrupted it, and then this change's own progress. Each
            // hop is upstream's `blendPoses` (`motion.ts:204`).
            var before: OpenBotAvatarPose?
            for step in blend.from {
                // A change of mood alone keeps the state's clock running on both sides, so a turn
                // under way stays one turn; a state that was left is held at the age it had.
                let age = step.state.id == id ? stateAge : step.age
                let shown = step.state.statePose(mood: step.mood, time: time, seed: seed,
                                                 reducedMotion: reducedMotion, stateAge: age)
                before = before.map { OpenBotAvatarPose.blended($0, shown, t: step.t) } ?? shown
            }
            if let before { pose = OpenBotAvatarPose.blended(before, pose, t: blend.t) }
        }
        // One eye schedule per bot: the shared face's frame wins over whatever the state drew, and it
        // is applied after the blend so nothing a host writes can skip it.
        if let eyeOverride {
            pose.blink = eyeOverride.blink
            pose.gazeX = eyeOverride.gazeX
            pose.gazeY = eyeOverride.gazeY
            pose.squint = eyeOverride.squint
        }
        return pose
    }

    /// The pose of this state at one moment, before any easing. A built-in runs its own branch; a
    /// definition runs the host's pose over the resting pose it is given. `motion.ts:527`.
    func statePose(mood: BotAvatarMood, time: Double, seed: UInt32, reducedMotion: Bool,
                   stateAge: Double?) -> OpenBotAvatarPose {
        if case .named(let state) = self {
            return state.pose(mood: mood, time: time, seed: seed, reducedMotion: reducedMotion,
                              stateAge: stateAge)
        }
        // Per-avatar phase offset, so several avatars on a page do not move in lockstep.
        let t = reducedMotion ? 0 : time + OpenBotAvatarState.noise(seed, 7) * 10
        var base = OpenBotAvatarPose()
        base.mood = mood
        base.yaw = OpenBotAvatarPose.restYaw
        base.pitch = OpenBotAvatarPose.restPitch
        base.arch = mood == .happy ? 1 : 0
        let context = StateContext(seed: seed,
                                   time: time,
                                   t: t,
                                   stateAge: stateAge,
                                   mood: mood,
                                   reducedMotion: reducedMotion,
                                   live: reducedMotion ? 0 : 1,
                                   sway: 1,
                                   wave: { period, phase in
                                       reducedMotion ? 0 : sin(2 * .pi * t / period + phase)
                                   },
                                   base: base,
                                   rest: { pace in
                                       OpenBotAvatarState.resting(seed: seed, t: t, mood: mood,
                                                                  reducedMotion: reducedMotion,
                                                                  pace: pace)
                                   })
        var pose = OpenBotAvatarPose.laid(over: base, given: definition.pose(context))
        // A definition has no row in the material's light table, so it borrows idle's: steady, and
        // the same on every material. A host that wants its own light can still set `pose.light`.
        if pose.light == base.light {
            pose.light = OpenBotAvatarState.idle.light(time: t, reducedMotion: reducedMotion)
        }
        pose.mood = mood
        return pose
    }
}

/// A change easing in over what was shown before. `t` 0…1; a host leaves it out once it reaches 1.
///
/// The poses it eases in from are a chain, oldest first, because a change that interrupts a change has
/// to continue from wherever the second one had got to rather than jump (`mood.ts:33`). One entry is
/// the ordinary case — a change of state or mood from a pose that was sitting still.
public struct OpenBotAvatarBlend: Hashable, Sendable {
    /// What was on screen, oldest first. The last entry is the pose being left now.
    public var from: [Step]
    /// How far this change has got, 0…1.
    public var t: Double

    /// One pose in the chain: the state and mood it was, the age it had, and how far the change *into*
    /// it had got when the next one interrupted it (1 for the oldest, which was fully shown).
    public struct Step: Hashable, Sendable {
        public var state: OpenBotAvatarStateChoice
        public var mood: BotAvatarMood
        public var age: Double?
        public var t: Double

        public init(state: OpenBotAvatarStateChoice, mood: BotAvatarMood, age: Double? = nil, t: Double = 1) {
            self.state = state
            self.mood = mood
            self.age = age
            self.t = t
        }
    }

    public init(from: [Step], t: Double) {
        self.from = from
        self.t = t
    }

    /// The ordinary case: one pose, fully shown, that this change eases away from.
    public init(from state: OpenBotAvatarStateChoice, mood: BotAvatarMood, age: Double? = nil, t: Double) {
        self.init(from: [Step(state: state, mood: mood, age: age)], t: t)
    }
}

public enum OpenBotAvatarEasing {

    /// Length of a change of state or mood, ms — upstream's `MOOD_MS` (`mood.ts:10`). Long enough that
    /// the eyes are seen to morph rather than cut, short enough that the bot answers at once.
    public static let changeMilliseconds = 420.0

    /// Eased progress of a change from elapsed time (smoothstep, clamped). `mood.ts:18`.
    public static func progress(elapsedMilliseconds: Double) -> Double {
        let x = min(1, max(0, elapsedMilliseconds / changeMilliseconds))
        return x * x * (3 - 2 * x)
    }
}

/// What a surface keeps between frames so a change of state or mood eases in from what was on screen.
///
/// Upstream's `createAnimator` (`animator.ts`) does this for every live avatar: it remembers the state
/// and mood shown, when the state began and what is still easing in, and hands each frame a `stateAge`
/// and a `motionBlend`. Ours is the same, without the look-at follow (this app's face never follows a
/// pointer), so a state — a name or a host's definition — eases in from the pose before it however it
/// was reached, and a change that interrupts a change continues from where it had got to.
///
/// It is stepped once per frame, and a frame is a pure function of what it returns.
public final class OpenBotAvatarStateAnimator {

    /// One frame's worth: how long the state has been showing, what to ease in from, and whether
    /// anything is still moving.
    public struct Step: Equatable {
        /// Seconds since the state began, its `startAge` included.
        public var stateAge: Double
        /// What to ease in from, if a change is under way.
        public var blend: OpenBotAvatarBlend?
        /// True while a change is still easing.
        public var moving: Bool
    }

    private struct Shown {
        var state: OpenBotAvatarStateChoice
        var mood: BotAvatarMood
        /// When the state began (offset back by its `startAge`).
        var began: Date
        /// When the change into it began.
        var since: Date
        /// What it is easing in from, if anything.
        var blend: OpenBotAvatarBlend?
    }

    private var shown: Shown?

    public init() {}

    /// Back to rest with no history, e.g. when the avatar is remounted.
    public func reset() { shown = nil }

    /// The state and mood at `now`, easing in from what was on screen before. `reducedMotion` switches
    /// at once: a calm frame has nothing to ease.
    public func step(state: OpenBotAvatarStateChoice,
                     mood: BotAvatarMood,
                     at now: Date,
                     reducedMotion: Bool) -> Step {
        guard var current = shown else {
            // An avatar that mounts `done` starts it at rest, as if it had just finished celebrating;
            // any other state starts afresh. `animator.ts:76-79`.
            let began = now.addingTimeInterval(-state.startAge)
            shown = Shown(state: state, mood: mood, began: began, since: now, blend: nil)
            return Step(stateAge: now.timeIntervalSince(began), blend: nil, moving: false)
        }
        let sameState = current.state.id == state.id
        // The same state given again may be a newer definition of it: that one is on screen from now on.
        if sameState { current.state = state }
        if !sameState || mood != current.mood {
            // A change of mood alone keeps the state's clock running; a state that was left is held at
            // the age it had.
            let age = now.timeIntervalSince(current.began)
            let reached = self.progress(of: current, now: now, reducedMotion: reducedMotion)
            let chain = Self.settled(current.blend, leaving: current.state, mood: current.mood,
                                     age: age, at: reached)
            current = Shown(state: state,
                            mood: mood,
                            began: sameState ? current.began : now.addingTimeInterval(-state.startAge),
                            since: now,
                            blend: reducedMotion ? nil : OpenBotAvatarBlend(from: chain, t: 0))
        }
        shown = current
        let t = progress(of: current, now: now, reducedMotion: reducedMotion)
        var blend: OpenBotAvatarBlend?
        if var easing = current.blend, t < 1 {
            easing.t = t
            blend = easing
        } else {
            shown?.blend = nil
        }
        return Step(stateAge: now.timeIntervalSince(current.began), blend: blend, moving: blend != nil)
    }

    private func progress(of shown: Shown, now: Date, reducedMotion: Bool) -> Double {
        reducedMotion ? 1 : OpenBotAvatarEasing.progress(elapsedMilliseconds: now.timeIntervalSince(shown.since) * 1000)
    }

    /// What a new change eases in from: the chain already on screen, with the pose being left added at
    /// the progress its own change had reached — so the pose continues from exactly where it is.
    ///
    /// A change that had all but finished is not carried (a tenth of a percent of a pose is not worth
    /// blending), and the chain is cut to a few levels, so rapid changes never grow it. `mood.ts:39`.
    static func settled(_ blend: OpenBotAvatarBlend?,
                        leaving state: OpenBotAvatarStateChoice,
                        mood: BotAvatarMood,
                        age: Double,
                        at t: Double) -> [OpenBotAvatarBlend.Step] {
        let rest = 1 - t
        if rest < 0.02 { return [OpenBotAvatarBlend.Step(state: state, mood: mood, age: age)] }
        var chain = blend?.from ?? []
        chain.append(OpenBotAvatarBlend.Step(state: state, mood: mood, age: age, t: t))
        if chain.count > 3 { chain.removeFirst(chain.count - 3) }
        return chain
    }
}
