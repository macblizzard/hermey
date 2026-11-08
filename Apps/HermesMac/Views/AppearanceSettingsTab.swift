import AppKit
import OpenBotUI
import SwiftUI

/// Settings → Appearance.
///
/// One control: how much of the desktop shows through the window. It is the only appearance
/// preference this app has, and it is stored in `UserDefaults` so a relaunch keeps it. The slider
/// stops at 55 %: below that the transcript is no longer readable over a bright desktop, and a
/// setting that can make the app unusable is not a setting worth shipping.
struct AppearanceSettingsTab: View {
    @AppStorage(WindowAppearance.opacityKey) private var opacity: Double = 1
    @AppStorage(ThemeRuntime.defaultsKey) private var themeID: String = ThemeCatalog.defaultID

    private var percent: Int { Int((opacity * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Theme")
                .font(TypeScale.font(Tokens.textLG, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)

            Text("Colours for the whole app. The same list is in the ⌘K palette.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            ThemePicker()

            Divider().padding(.vertical, 2)

            Text("Window")
                .font(TypeScale.font(Tokens.textLG, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)

            Text("How opaque the window is. Lower values let the desktop show through.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(Tokens.textMuted)
                    .font(.system(size: 11))

                Slider(value: $opacity,
                       in: WindowAppearance.minimumOpacity...1,
                       step: 0.01)
                    .accessibilityIdentifier("appearanceOpacitySlider")

                Text("\(percent) %")
                    .font(.system(size: TypeScale.caption, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }

            Button("Opaque") {
                opacity = 1
            }
            .disabled(opacity >= 0.999)

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.canvas)
        // The settings window is its own scene; re-creating its content is what lets it wear the
        // palette the user just chose.
        .id(themeID)
    }
}
