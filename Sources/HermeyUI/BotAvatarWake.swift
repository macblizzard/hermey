import Foundation
import HermesKit

/// What a bot does when the pointer arrives: a greeting, then the reference's own idle float.
///
/// Mohammad's report (2026-11-24): *"on mouse over on any bots in bot list the bot avatar should
/// move/animate"*. The row already knows when the pointer is over it — that is the same hover state
/// the ⋯ button appears on — so the face is woken from there; nothing here measures the pointer.
///
/// **A greeting, not a performance.** `BotAvatarPerformance` is what a *busy* face does (hops, flips,
/// double takes, a squint): it answers "look, work is happening". A hovered row is not working, so
/// this borrows no part of that. It plays one short, quiet hello — a hop with a lean, and the eyes
/// turning toward the row's content, which is where the pointer must be to hover the row — and then
/// settles into the float the reference already draws for `idle`. That float is not re-authored here:
/// once the greeting is over, `BotAvatarMotion.bodyPose(activity: .idle, …)` and its own eye loop are
/// asked for the frame, exactly as an idle face that was allowed to move would draw.
///
/// **Nothing permanent is relaxed.** The size floor and the `animates: false` that keep a twenty-row
/// list cheap are still the resting rule; waking is a *state of the row*, not a change to the rule.
/// While the pointer is on one row, that row draws at `frameInterval` — the busy beat, 30 Hz, never
/// faster than a working face — and every other row keeps its paused timeline.
///
/// **Reduce Motion gets no hop.** A caller passes `reduceMotion` in; when it is true the greeting is
/// never sampled and the face is drawn exactly as it is at rest (the caller's own `moves` gate
/// already decided whether the quiet idle float may run). No shape change, no blink invented here.
public enum BotAvatarWake {
    /// How long the hello lasts before the face settles into the float, in seconds.
    ///
    /// Short on purpose: the pointer is already moving on, and a greeting still playing at 2 s reads
    /// as a busy face rather than a friendly one.
    public static let greetingDuration: Double = 0.9

    /// The beat a woken face draws at: the busy beat, which is the ceiling this feature may spend.
    public static let frameInterval: Double = BotAvatarMotion.frameInterval

    /// Whether a face may be woken at all, given the surface and the system.
    ///
    /// Deliberately says nothing about `animates` or the size floor: those are the *resting* rule,
    /// and the point of a hover is to lift them for as long as the row is the one being used. It says
    /// nothing about the activity either — a hovered face is awake, never busy.
    public static func allows(wakesOnHover: Bool,
                              reduceMotion: Bool,
                              appAllowsMotion: Bool,
                              isActiveScene: Bool) -> Bool {
        wakesOnHover && !reduceMotion && appAllowsMotion && isActiveScene
    }

    /// The frame at an instant.
    ///
    /// `start` is the wall-clock moment the pointer arrived (nil when the face is merely awake and the
    /// greeting is already over). `gaze` is the direction the eyes turn for the hello: +1 is toward
    /// the row's content, which is where a pointer over the row's leading avatar must be.
    public static func frame(at time: Double,
                             since start: Double?,
                             traits: BotAvatarMotionTraits,
                             gaze: Double = 1) -> BotAvatarMotion.Frame {
        // Where the hello settles: the reference's own idle float and idle glance. Reused rather
        // than re-authored, so a woken face and an idle face that is allowed to move agree.
        let settled = BotAvatarMotion.Frame(
            body: BotAvatarMotion.bodyPose(activity: .idle, at: time, traits: traits),
            eyes: BotAvatarMotion.eyePose(traits: traits, at: time)
        )
        guard let start else { return settled }
        let elapsed = time - start
        guard elapsed < greetingDuration else { return settled }

        // 0 → 1 → 0 over the greeting: the hop rises, turns its eyes, and comes home.
        let t = max(0, elapsed / greetingDuration)
        let arc = sin(.pi * t)

        let body = BotAvatarPose(
            // A tenth of the face's own side is a hop; a fraction, like every other pose here, so a
            // 20 pt row face and a 96 pt header face move by the same amount *of themselves*.
            translateY: -0.10 * arc,
            // A lean toward the content, a couple of degrees: a tilt, not a turn.
            rotate: gaze * 3.0 * arc,
            scaleX: 1 - 0.03 * arc,
            scaleY: 1 + 0.05 * arc,
            brightness: 0.05 * arc
        )

        // The eyes lead the hop: they are on the pointer by the time the body has left the ground,
        // and they come back to centre as it lands.
        let eyes = BotAvatarEyePose(
            offsetX: gaze * 0.20 * min(1, t * 4),
            offsetY: -0.06 * arc
        )

        return BotAvatarMotion.Frame(body: body, eyes: eyes)
    }
}
