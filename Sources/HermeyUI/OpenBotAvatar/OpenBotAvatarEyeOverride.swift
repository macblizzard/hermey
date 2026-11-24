import Foundation

/// The old face's eyes, handed to the drawn one.
///
/// The shape-and-palette face has had a motion model for two releases: `BotAvatarMotion.frame`
/// runs the reference's authored eye tracks and `BotAvatarPerformance` darts and squints them
/// between the acting. The drawn avatar has none of it — it blinks and looks around on a quieter
/// schedule of its own (`OpenBotAvatarState.blink`). Rather than grow a second eye clock inside the
/// drawn renderer, `BotAvatarView` evaluates *one* frame per tick with
/// `BotAvatarMotion.performedFrame` and passes that frame's eyes down as this override, so both
/// faces of the same bot blink and look on the same schedule.
///
/// **Nil is the whole of the old behaviour.** A caller that passes nothing (the pet, the editor, any
/// surface that draws `OpenBotAvatarView` itself) leaves every channel of the drawn pose exactly as
/// it was; the posture below is only ever *given* by the shared face.
///
/// The channels are the drawn pose's own (`OpenBotAvatarPose`), so this is a hand-over between two
/// existing vocabularies rather than a third one:
///
/// * `blink` — 0 open, 1 shut: the drawn renderer's own openness channel;
/// * `gazeX`/`gazeY` — −1…1 of the renderer's declared eye travel (`OpenBotAvatarGeometry.gazeX`);
/// * `squint` — extra lid narrowing, 0…1, multiplying the openness alongside `blink`.
public struct OpenBotAvatarEyeOverride: Hashable, Sendable {
    /// 0 open, 1 shut.
    public var blink: Double
    /// Look direction, −1…1 of the renderer's full travel, per axis.
    public var gazeX: Double
    public var gazeY: Double
    /// Extra narrowing on top of `blink`, 0…1.
    public var squint: Double

    public init(blink: Double = 0,
                gazeX: Double = 0,
                gazeY: Double = 0,
                squint: Double = 0) {
        self.blink = blink
        self.gazeX = gazeX
        self.gazeY = gazeY
        self.squint = squint
    }

    /// The shape face's eye pose, in the channels above.
    ///
    /// Two conversions, both here so neither renderer has to know the other's box:
    ///
    /// * **Openness.** The shape face's lid is a single number: `BotAvatarEyePose.scaleY` is its
    ///   openness (1 open, 0.06 shut, with the state's own lid multiplied in). So all of that
    ///   closure becomes `blink` and `squint` stays 0. Splitting the same closure across both would
    ///   shut the drawn eye by `(1 - blink)·(1 - 0.4·squint)` — twice as hard as the face this is
    ///   copying, which is the one way this hand-over can look wrong.
    /// * **Gaze.** Both faces move the eyes as a fraction of their own eye box, and the boxes are
    ///   different sizes. The shape face's is 60 × 52 units of a 259-unit view (its width and its
    ///   height — `BotAvatarGeometry.shipped.eyes`); the drawn box is the 100-unit definition, where
    ///   the renderer's full travel is `OpenBotAvatarGeometry.gazeX` / `gazeY`. The two gains below
    ///   are that ratio per axis, so one of the old face's darts arrives as most of the drawn socket
    ///   and the renderer's own clamp keeps whatever is left inside it.
    public init(eyes: BotAvatarEyePose) {
        self.init(blink: min(max(1 - eyes.scaleY, 0), 1),
                  gazeX: eyes.offsetX * Self.gazeGainX,
                  gazeY: eyes.offsetY * Self.gazeGainY,
                  squint: 0)
    }

    /// Shape-face eye fraction → drawn-face gaze units, per axis: the old eye box's width (60) and
    /// height (52) in units of its 259-unit view, expressed in the drawn face's 100-unit box, over
    /// the renderer's full travel for one gaze unit.
    public static let gazeGainX: Double = 60.0 * (100.0 / 259.0) / OpenBotAvatarGeometry.gazeX
    public static let gazeGainY: Double = 52.0 * (100.0 / 259.0) / OpenBotAvatarGeometry.gazeY
}
