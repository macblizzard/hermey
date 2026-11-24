import Foundation
import SwiftUI

/// The composer's session row: the model pill at the leading edge, the context count at the trailing
/// one.
///
/// Both halves in one row rather than one inside the other, which is what Mohammad asked for after
/// seeing the count truncate the model name: the pill is as wide as its model needs, the count is as
/// wide as its number needs, and the space between them is the gap — so neither can squeeze the other
/// on a narrow phone. It is still chrome, still outside the text field, and still one line.
public struct ComposerSessionRow: View, Equatable {
    private let provider: String?
    private let model: String?
    private let used: Int?
    private let limit: Int?
    private let isEnabled: Bool
    /// Opening the picker belongs to the caller — the Mac opens the sheet its bot panel does, the
    /// phone the sheet its drawer does. This row knows none of that.
    private let onOpen: () -> Void

    public init(provider: String?,
                model: String?,
                used: Int?,
                limit: Int?,
                isEnabled: Bool = true,
                onOpen: @escaping () -> Void) {
        self.provider = provider
        self.model = model
        self.used = used
        self.limit = limit
        self.isEnabled = isEnabled
        self.onOpen = onOpen
    }

    /// The five values that decide what is drawn; the closure is left out because it is rebuilt on
    /// every parent body pass and comparing it would defeat `.equatable()` entirely.
    public static func == (lhs: ComposerSessionRow, rhs: ComposerSessionRow) -> Bool {
        lhs.provider == rhs.provider
            && lhs.model == rhs.model
            && lhs.used == rhs.used
            && lhs.limit == rhs.limit
            && lhs.isEnabled == rhs.isEnabled
    }

    public var body: some View {
        HStack(spacing: 8) {
            ComposerModelPill(provider: provider,
                              model: model,
                              isEnabled: isEnabled,
                              onOpen: onOpen)
            Spacer(minLength: 8)
            if let tokens = SessionLine.context(used: used, limit: limit) {
                // The count keeps its width: it is the number the reader came for, and it is the
                // half with no room to truncate.
                Text(tokens)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Context used, \(tokens)")
            }
        }
    }
}
