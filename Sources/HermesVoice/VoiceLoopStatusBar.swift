import SwiftUI

/// The visible half of the loop: what it is doing, what was heard, and the way out.
///
/// One line, always present while the conversation is live, because a hands-free microphone with no
/// indicator is indistinguishable from a broken app — and the whole point is that the user can put
/// the phone down. It carries three facts and one action:
///
/// * the state (`Listening` / `Thinking` / `Speaking` / `Starting…` / `Voice stopped`), with a
///   symbol that breathes while the microphone is open;
/// * the last thing the host heard, so a mis-hearing is visible at a glance;
/// * how to end it by voice (`Say "stop" to end`), plus a Stop button for when talking is not an
///   option.
///
/// No glass and no material: it sits inside the composer's column, drawn with the same text tokens
/// as the hint line it replaces.
public struct VoiceLoopStatusBar: View {
    @ObservedObject private var loop: VoiceLoopController
    private let tint: Color
    private let onStop: () -> Void

    public init(loop: VoiceLoopController,
                tint: Color = .accentColor,
                onStop: (() -> Void)? = nil) {
        self.loop = loop
        self.tint = tint
        self.onStop = onStop ?? { loop.stop() }
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: loop.state.glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(loop.state == .failed ? Color.orange : tint)
                .symbolEffect(.variableColor.iterative,
                              isActive: loop.state == .listening || loop.state == .speaking)
                .frame(width: 16)

            Text(loop.state.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)

            if let detail = detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 6)

            if let notice = loop.notice, loop.state == .off {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if loop.state.ownsMicrophone {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help("End the conversation")
                #endif
                .accessibilityLabel("End the voice conversation")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        // The whole line is one announcement: a screen reader should say "Listening. Say stop to
        // end", not spell out the glyph.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// The second half of the line: what was heard, why it stopped, or how to stop, never both —
    /// one of them is always the more useful thing.
    private var detail: String? {
        // A failure with no sentence is the silence this strip exists to end: the state word alone
        // says the conversation stopped and nothing about why or what to do.
        if loop.state == .failed, let message = loop.errorMessage, !message.isEmpty {
            return message
        }
        if let heard = loop.heardText, loop.state == .thinking || loop.state == .speaking {
            return "“\(heard)”"
        }
        if loop.state.ownsMicrophone { return VoicePolicy.stopHint() }
        return nil
    }

    private var accessibilityText: String {
        switch loop.state {
        case .listening:
            return "Listening. \(VoicePolicy.stopHint())."
        case .thinking:
            return loop.heardText.map { "Thinking about: \($0)." } ?? "Thinking."
        case .speaking:
            return "Speaking the reply."
        case .starting:
            return "Starting the voice conversation."
        case .failed:
            return "Voice stopped. \(loop.errorMessage ?? "")"
        case .off:
            return loop.notice ?? "Voice conversation is off."
        }
    }
}
