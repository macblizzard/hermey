import SwiftUI

/// The bot's own face, turning, while it works.
///
/// The wheel that used to sit beside "Thinking…" said *something* is happening. This says **which
/// bot** is happening: the face from the roster, the header and the panel, turning about its own
/// vertical axis so it reads as a coin standing on an edge rather than as a circle being redrawn
/// (asked for 2026-11-14).
///
/// Rotation and not a wheel because a wheel is a machine's idea of progress and a face is the app's
/// idea of a worker — and because the turn is the same trick iOS uses for a "please wait" mark,
/// which is already the vocabulary of every phone this app runs on.
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

    /// A turn every 1.6 s, eased by the perspective rather than by a curve: at the half-way point the
    /// face is edge-on and briefly thin, which is what sells the coin rather than a flipped image.
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
        .rotation3DEffect(.degrees(degrees),
                          axis: (x: 0, y: 1, z: 0),
                          anchor: .center,
                          perspective: 0.42)
        // A hair of shadow under it, so the turn reads as a solid object against the canvas.
        .shadow(color: .black.opacity(0.28), radius: size * 0.08, y: size * 0.04)
    }
}
