import HermesKit
import SwiftUI

/// The line that stands in for the answer before the first token arrives.
///
/// "Hermey is working…" is true and says nothing. Hermes has a voice — a kaomoji and a verb — so the
/// wait is narrated in it, and the phrase moves every few seconds so a slow tool cannot make the
/// app look frozen. The phrase is presentation, not host state: it never claims to know what the
/// host is doing, only that something is.
public struct WorkingStatus: View {
    /// Whose work this is. With a bot the row wears that bot's face, turning in place of the wheel —
    /// a wheel says something is happening, a face says *which bot* is happening. A caller with no
    /// bot (a room, a host with no bots yet) still gets the wheel.
    public var bot: String?
    /// What that bot is doing, as `AppModel.activity(forBot:)` reports it. Defaulted to `working`
    /// because that is what this row exists to say.
    public var activity: BotAvatarActivity
    /// The bot's stored face, so the row and the roster cannot disagree about which body it wears.
    public var color: String?

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

    public init(bot: String? = nil,
                activity: BotAvatarActivity = .working,
                color: String? = nil) {
        self.bot = bot
        self.activity = activity
        self.color = color
        // A different opening phrase each turn: a fixed one reads as a stuck label.
        _index = State(initialValue: Int(Date().timeIntervalSince1970) % WorkingStatus.phrases.count)
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let bot {
                BotAvatarView(identity: bot,
                              color: color,
                              activity: activity,
                              size: 16,
                              // This row is only drawn while a turn is in flight, and the face is
                              // the whole status indicator — so it moves even at 16 pt, past the
                              // house floor that keeps list-sized faces cheap.
                              animates: true,
                              animatingFrom: 0)
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
