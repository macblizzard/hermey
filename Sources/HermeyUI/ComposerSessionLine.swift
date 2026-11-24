import Foundation
import SwiftUI

/// What the composer's chrome says about the session: `provider/model`, and how full its context is.
///
/// **One rendering for two apps.** The owner photographed a line reading
/// `Opencode-Go/Deepseek-v4.1-flash   |   540k/1M Tokens` over the compose box and asked for it on
/// both apps, tastefully. The phone already owned one half of the rule — `TokenCount`, the same
/// `540k` / `1M` the header prints — and the Mac owned none of it, so the two would have drifted the
/// moment either was edited. Both now print through these two functions.
public enum SessionLine {
    /// `opencode-go/deepseek-v4.1-flash`.
    ///
    /// The host's catalogue names the running model (`deepseek-v4.1-flash`) and its provider
    /// (`opencode-go`) as two fields, and a name that already carries a slash is left alone rather
    /// than prefixed twice. An empty provider is not invented: the model is printed on its own.
    public static func model(provider: String?, model: String?) -> String? {
        let name = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard !name.contains("/") else { return name }
        let slug = (provider ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return name }
        return "\(slug)/\(name)"
    }

    /// `540k/1M Tokens` — `TokenCount`'s rule, so the composer and the header cannot disagree.
    ///
    /// Both halves come from the host: `used` from the last completed turn's `usage`, `limit` from
    /// the window it reported. With a window, both are printed; with only `used`, the count is
    /// printed without a limit rather than against a guessed one; with neither, there is no line at
    /// all — a made-up `1M` is exactly the kind of number a reader would trust.
    public static func context(used: Int?, limit: Int?) -> String? {
        guard let used, used >= 0 else { return nil }
        guard let limit, limit > 0 else { return "\(TokenCount.short(used)) Tokens" }
        return "\(TokenCount.short(used))/\(TokenCount.short(limit)) Tokens"
    }
}

/// The line over the composer's field: quiet chrome, never the message.
///
/// It is deliberately **not** part of the field. The field is where the user types; this reads the
/// session and is drawn above the card, so it can be as narrow as it likes without reflowing a
/// character, and its own height is one line whether the window is 1440 pt or 424 pt wide. Two rules
/// keep it from ever costing the reader anything:
///
/// * **it never wraps or grows.** One line, tail-truncated, and the width it truncates against is the
///   composer's own; `ViewThatFits` drops the token count on a narrow window and leaves the model
///   name, which is the half that identifies the conversation.
/// * **it cannot repaint while typing.** It reads four values and nothing else — no draft, no
///   geometry — and it is `Equatable`, so the call sites use `.equatable()` and a keystroke that
///   changes only the text in the field does not lay this line out again.
public struct ComposerSessionLine: View, Equatable {
    private let provider: String?
    private let model: String?
    private let used: Int?
    private let limit: Int?

    public init(provider: String?, model: String?, used: Int?, limit: Int?) {
        self.provider = provider
        self.model = model
        self.used = used
        self.limit = limit
    }

    public var body: some View {
        let name = SessionLine.model(provider: provider, model: model)
        let tokens = SessionLine.context(used: used, limit: limit)

        return Group {
            if let name, let tokens {
                // The full line where it fits, the model alone where it does not: the model is the
                // half that identifies the conversation, so it is the half that survives a narrow
                // window. `fixedSize` on the first candidate is what lets `ViewThatFits` compare
                // ideal widths instead of accepting a line that has already been squeezed.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(name)
                        Text("·").opacity(0.7)
                        Text(tokens)
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    Text(name)
                }
            } else if let name {
                Text(name)
            } else if let tokens {
                Text(tokens)
            }
        }
        .font(TypeScale.font(TypeScale.caption))
        .foregroundStyle(Tokens.textDim)
        .lineLimit(1)
        .truncationMode(.tail)
        // Chrome, not a control: it must not eat a click meant for the field under it.
        .allowsHitTesting(false)
    }
}
