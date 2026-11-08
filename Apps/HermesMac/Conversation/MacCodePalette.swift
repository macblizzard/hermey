import HermesRender
import OpenBotUI
import SwiftUI

/// Syntax colours for code, as token *roles* rather than raw hex.
///
/// `SyntaxHighlighter` tags every run with a `TokenKind`; this maps that role onto the
/// palette the design system already owns. No new colour is invented here — a keyword is
/// `Tokens.accentText`, a comment is the dim text token, and so on — so the code block keeps
/// the same contrast budget as the prose around it.
enum MacCodePalette {
    static func color(for kind: TokenKind?) -> Color {
        guard let kind else { return Tokens.textSecondary }
        switch kind {
        case .keyword, .builtin, .type, .attribute:
            return Tokens.accentText
        case .string:
            return Tokens.success
        case .number:
            return Tokens.warning
        case .comment:
            return Tokens.textDim
        case .punctuation:
            return Tokens.textMuted
        case .property, .variable:
            return Tokens.textSecondary
        case .plain:
            return Tokens.textSecondary
        }
    }
}
