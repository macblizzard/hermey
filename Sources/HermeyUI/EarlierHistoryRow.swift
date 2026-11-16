import SwiftUI

/// The transcript's top edge: "load earlier messages".
///
/// A long conversation is paged — the host ships only its newest page, because one multi-megabyte
/// `session.resume` frame is a message iOS refuses to deliver ("Message too long"), which is why a
/// long bot chat sat on an empty screen with a reconnect loop. The transcript on screen therefore
/// starts mid-history and this row is how the reader walks back.
///
/// Drawn only while the host still holds older rows (`AppModel.hasEarlierHistory`), and disabled
/// while a page is in flight so a fast double tap cannot ask for the same page twice.
public struct EarlierHistoryRow: View {
    public let isLoading: Bool
    public let total: Int
    public let action: () -> Void

    public init(isLoading: Bool, total: Int = 0, action: @escaping () -> Void) {
        self.isLoading = isLoading
        self.total = total
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.circle")
                }
                Text(isLoading ? "Loading earlier messages…" : "Load earlier messages")
            }
            .font(TypeScale.font(TypeScale.sm))
            .foregroundStyle(Tokens.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityIdentifier("earlierHistory")
        .accessibilityLabel(total > 0 ? "Load earlier messages, \(total) in this conversation"
                                      : "Load earlier messages")
    }
}
