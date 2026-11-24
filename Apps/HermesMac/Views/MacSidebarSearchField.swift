import SwiftUI
import HermeyUI

// TODO(design-system): the sidebar's search field is not in HermeyUI yet. Replace this
// with the design system's own field as soon as it lands; the geometry here (32 pt tall,
// 9 pt control radius, `Tokens.control`) is what the spec asks for.

/// An inline filter field: the bot panel's "Search bots and messages" and the settings sheet's
/// model search.
///
/// It is one row — small magnifier, text, clear — at the panel's 200 pt floor as well as in a
/// sheet, so its own padding stays at 8 and nothing in it is fixed-width except the two glyphs.
struct MacSidebarSearchField: View {
    @Binding var text: String
    /// The field says what it filters; the settings sheet searches a model catalogue with it.
    var prompt: String = "Search sessions"
    /// Up / down while the field has the keyboard. A one-line field has nowhere for a caret to go,
    /// so on the panel these walk the list below it — the same bargain the ⌘K palette makes.
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    /// Return. `nil` leaves the field's own submit alone.
    var onSubmit: (() -> Void)? = nil
    /// Escape. `nil` leaves the key to whoever else owns it (the shell's own catcher).
    var onEscape: (() -> Void)? = nil
    /// Take the caret when the field appears. The panel's field is opened by a button, so the next
    /// keystroke should be typing rather than a click.
    var autofocuses: Bool = false

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
                .onSubmit { onSubmit?() }
                .onKeyPress(.upArrow) {
                    guard let onMoveUp else { return .ignored }
                    onMoveUp()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard let onMoveDown else { return .ignored }
                    onMoveDown()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard let onEscape else { return .ignored }
                    onEscape()
                    return .handled
                }
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
                .hermeyFocusQuiet()
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
        // Opened by a button, so the caret arrives with it: one beat for the field to exist in the
        // window, which is when a `TextField` actually takes first responder.
        .onAppear {
            guard autofocuses else { return }
            focused = true
            Task {
                try? await Task.sleep(nanoseconds: 60_000_000)
                focused = true
            }
        }
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
