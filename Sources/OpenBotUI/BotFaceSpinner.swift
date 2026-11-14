import SwiftUI

/// The bot's own face, turning, while it works.
///
/// The wheel that used to sit beside "Thinking…" said *something* is happening. This says **which
/// bot** is happening: the face from the roster, the header and the panel, turning about its own
/// vertical axis so it reads as a coin standing on an edge rather than as a circle being redrawn
/// (asked for 2026-11-14).
///
/// It turns **in the plane of the screen** — the z axis — rather than swinging toward the viewer, so
/// the whole face stays readable at every angle and the turn reads as the app's own spinner rather
/// than as a coin being flipped (the y-axis version was asked to be changed, 2026-11-14).
///
/// Cost: one `TimelineView` at 30 fps, drawing a silhouette, three light layers and two eyes —
/// bounded to the one row that is streaming, and paused the moment it is not.
public struct BotFaceSpinner: View {
    public var face: BotFace
    public var size: CGFloat
    public var isWorking: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(face: BotFace, size: CGFloat = 18, isWorking: Bool = true) {
        self.face = face
        self.size = size
        self.isWorking = isWorking
    }

    private var spins: Bool {
        isWorking && BotFaceMotion.allows(reduceMotion: reduceMotion, size: max(size, 18))
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spins)) { context in
            faceDrawing(degrees: spins ? angle(at: context.date) : 0)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// A turn every 1.6 s, continuous and linear: a spinner that eases reads as a pulse, and the
    /// point of this one is that it keeps going.
    private func angle(at date: Date) -> Double {
        let turns = date.timeIntervalSinceReferenceDate / 1.6
        return (turns - turns.rounded(.down)) * 360
    }

    private func faceDrawing(degrees: Double) -> some View {
        ZStack {
            BotSilhouette(face.shape)
                .fill(face.color.swatch)
            BotFaceLight(icon: face.shape, size: size)
            // No blink here: a face that turns *and* blinks is a face having a moment.
            BotEyes(size: size, tilt: face.shape.eyeTilt)
        }
        .frame(width: size, height: size)
        // The z axis: the face turns flat on the screen, the way a spinner does, and stays legible
        // through the whole turn. No perspective, because there is no depth to foreshorten.
        .rotationEffect(.degrees(degrees))
    }
}
