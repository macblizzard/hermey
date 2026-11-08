import Foundation
import OpenBotUI

/// Token counts, printed the way the header prints them: `12k / 1M`.
///
/// One implementation so the conversation header, the settings threshold field and any
/// future surface agree — the same number must not read `1.0m` in one place and `1M` in
/// another. No thousands separators: these are estimates, and a comma implies a precision
/// the provider does not report.
enum MobileTokens {
    /// The shared rule (`TokenCount`), so the phone and the desktop print one number the same way.
    static func short(_ value: Int) -> String { TokenCount.short(value) }

    /// `200000` for a text field the user types into — digits only, no suffix.
    static func digits(_ value: Int) -> String {
        String(max(0, value))
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
