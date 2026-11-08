import SwiftUI
import OpenBotUI

// TODO(design-system): the sidebar's search field is not in OpenBotUI yet. Replace this
// with the design system's own field as soon as it lands; the geometry here (32 pt tall,
// 9 pt control radius, `Tokens.control`) is what the spec asks for.

/// An inline filter field: the bot panel's "Search bots" and the settings sheet's model search.
///
/// It is one row — small magnifier, text, clear — at the panel's 200 pt floor as well as in a
/// sheet, so its own padding stays at 8 and nothing in it is fixed-width except the two glyphs.
struct MacSidebarSearchField: View {
    @Binding var text: String
    /// The field says what it filters; the settings sheet searches a model catalogue with it.
    var prompt: String = "Search sessions"

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(focused ? Tokens.textMuted : Tokens.textDim)

            TextField("",
                      text: $text,
                      prompt: Text(prompt).foregroundColor(Tokens.textPlaceholder))
                .textFieldStyle(.plain)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textPrimary)
                .tint(Tokens.accent)
                .focused($focused)
                .accessibilityLabel(prompt)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textDim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear \(prompt.lowercased())")
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .fill(Tokens.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .strokeBorder(focused ? Tokens.borderFocus : Tokens.borderStrong, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
        .onTapGesture { focused = true }
    }
}

private struct MacSidebarSearchFieldPreview: View {
    @State private var empty = ""
    @State private var filled = "vault"

    var body: some View {
        VStack(spacing: 10) {
            MacSidebarSearchField(text: $empty)
            MacSidebarSearchField(text: $filled)
        }
        .padding(14)
        .frame(width: 280)
        .background(Tokens.sidebar)
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Sidebar search") {
    MacSidebarSearchFieldPreview()
}
#endif
