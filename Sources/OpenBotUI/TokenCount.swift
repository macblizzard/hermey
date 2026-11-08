import Foundation

/// One rendering of "how many tokens is that".
///
/// Three implementations disagreed: the phone printed `12.5k`, Settings printed `12k` (it rounded
/// the thousands) and the chat header printed `13k` (it rounded the raw number first). The same
/// context window therefore read differently on three screens of the same app. One decimal below
/// ten thousand, whole thousands above it — the rule the reader can predict.
public enum TokenCount {
    public static func short(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            let millions = Double(tokens) / 1_000_000
            return millions == millions.rounded()
                ? "\(Int(millions))M"
                : String(format: "%.1fM", millions)
        }
        if tokens >= 10_000 { return "\(Int((Double(tokens) / 1_000).rounded()))k" }
        if tokens >= 1_000 {
            let thousands = Double(tokens) / 1_000
            return thousands == thousands.rounded()
                ? "\(Int(thousands))k"
                : String(format: "%.1fk", thousands)
        }
        return "\(tokens)"
    }
}
