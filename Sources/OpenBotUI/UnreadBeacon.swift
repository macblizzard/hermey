import SwiftUI

/// The unread mark: a dot that breathes, so "there is something in here you have not read" cannot
/// be mistaken for the static presence dot beside it.
///
/// The halo is a blurred circle whose opacity follows a cosine, not a `repeatForever` animation:
/// animation requests issued from `onAppear` do not tick inside this app's `NSHostingView` (see the
/// wire-protocol notes), and a run-loop timer is state the view actually re-renders from. One
/// publisher is shared by every row, so twenty unread bots cost one timer, not twenty.
public struct UnreadBeacon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 12 Hz is enough for a ~2.6 s breath and a twelfth of the ring's cost.
    private static let ticker = Timer.publish(every: 1.0 / 12.0, on: .main, in: .common)
        .autoconnect()

    private let diameter: CGFloat
    @State private var phase: Double = 0.35

    public init(diameter: CGFloat = 6) {
        self.diameter = diameter
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(Tokens.success.opacity(0.16 + 0.20 * glow))
                .frame(width: diameter * 2.8, height: diameter * 2.8)
                .blur(radius: diameter * 0.6)
            Circle()
                .fill(Tokens.success)
                .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter * 2.8, height: diameter * 1.6)
        .onReceive(Self.ticker) { _ in
            guard !reduceMotion else { return }
            phase += 0.045
            if phase >= 1 { phase -= 1 }
        }
        .accessibilityLabel("unread")
        .accessibilityHidden(false)
    }

    /// 0 at the dimmest point of the breath, 1 at its brightest.
    private var glow: Double {
        reduceMotion ? 0.6 : 0.5 - 0.5 * cos(phase * 2 * .pi)
    }
}

#if DEBUG
#Preview("Unread beacon") {
    HStack(spacing: 12) {
        UnreadBeacon()
        UnreadBeacon(diameter: 8)
    }
    .padding()
    .background(Tokens.surface)
}
#endif
