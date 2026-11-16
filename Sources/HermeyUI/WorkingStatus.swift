import SwiftUI

/// The line that stands in for the answer before the first token arrives.
///
/// "Hermey is working…" is true and says nothing. Hermes has a voice — a kaomoji and a verb — so the
/// wait is narrated in it, and the phrase moves every few seconds so a slow tool cannot make the
/// app look frozen. The phrase is presentation, not host state: it never claims to know what the
/// host is doing, only that something is.
public struct WorkingStatus: View {
    /// Whose work this is. When a face is given, it turns in place of the wheel — a wheel says
    /// something is happening, a face says *which bot* is happening. The caller that has no face
    /// (a room, a host with no bots yet) still gets the wheel.
    public var face: BotFace?

    @State private var index: Int

    private let ticker = Timer.publish(every: 3.2, on: .main, in: .common).autoconnect()

    /// The rotations. They are written to be read quickly and to sound like a person thinking,
    /// because that is what the row is standing in for.
    static let phrases: [String] = [
        "◉_◉ deliberating…",
        "(´･_･`) musing…",
        "(¬‿¬) pondering…",
        "٩(๑❛ᴗ❛๑)۶ thinking it through…",
        "(・_・;) untangling…",
        "(°ロ°)☝ looking closely…",
        "(´-ω-`) chewing on it…",
        "(￣▽￣)ノ working…",
    ]

    public init(face: BotFace? = nil) {
        self.face = face
        // A different opening phrase each turn: a fixed one reads as a stuck label.
        _index = State(initialValue: Int(Date().timeIntervalSince1970) % WorkingStatus.phrases.count)
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let face {
                BotFaceSpinner(face: face, size: 16)
            } else {
                SpinningRing(color: Tokens.accent, size: 11, lineWidth: 1.5)
            }

            Text(WorkingStatus.phrases[index % WorkingStatus.phrases.count])
                .font(TypeScale.font(Tokens.textMD))
                .foregroundStyle(Tokens.textMuted)
                .lineLimit(1)
                .contentTransition(.opacity)

        }
        .padding(.vertical, 2)
        .onReceive(ticker) { _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                index += 1
            }
        }
        .accessibilityLabel("Hermey is working")
    }
}
