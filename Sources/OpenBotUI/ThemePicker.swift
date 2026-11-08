import SwiftUI

/// Picking a theme, on both platforms.
///
/// A theme is a swatch you can see, not a name in a pop-up: the row draws each palette's own canvas,
/// raised surface and accent, so the choice is made against the thing it changes. Selecting writes
/// the choice twice on purpose — into the runtime first (so the redraw that follows already wears the
/// new palette) and then into `UserDefaults`.
public struct ThemePicker: View {
    @AppStorage(ThemeRuntime.defaultsKey) private var themeID: String = ThemeCatalog.defaultID

    public init() {}

    public var body: some View {
        #if os(iOS)
        // A grid on the phone: a horizontal scroller inside a settings row is half-visible and its
        // pan competes with the list's own scroll, which made the themes look like a preview rather
        // than something you can pick.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10, alignment: .leading)],
                  alignment: .leading,
                  spacing: 14) {
            ForEach(ThemeCatalog.all) { theme in
                button(for: theme)
            }
        }
        .padding(.vertical, 4)
        .accessibilityLabel("Theme")
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ThemeCatalog.all) { theme in
                    button(for: theme)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel("Theme")
        #endif
    }

    private func button(for theme: ThemePalette) -> some View {
        let isSelected = theme.id == themeID
        return Button {
            // Runtime first: the view tree is re-created from the new `themeID`, and it must not
            // draw one frame in the old palette.
            ThemeRuntime.apply(id: theme.id)
            themeID = theme.id
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 0) {
                    ForEach(Array(theme.swatch.enumerated()), id: \.offset) { _, color in
                        Rectangle().fill(color)
                    }
                }
                .frame(width: 54, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? Tokens.accent : Tokens.borderStrong,
                                      lineWidth: isSelected ? 1.5 : 1)
                )

                Text(theme.name)
                    .font(TypeScale.font(TypeScale.caption, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Tokens.textPrimary : Tokens.textMuted)
                    .lineLimit(1)
            }
            .frame(width: 70)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
