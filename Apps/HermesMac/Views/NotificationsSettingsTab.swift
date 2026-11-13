import AppKit
import HermesAppKit
import OpenBotUI
import SwiftUI
import UserNotifications

/// Desktop notifications: the switch, the system's answer to it, and who to stay quiet about.
///
/// The switch is one setting shared with the phone through `AppModel` — the *permission* is not,
/// because the system grants it per app. That is why this tab has both: a toggle the app owns and
/// a status line the app can only report.
struct NotificationsSettingsTab: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var notifier = ReplyNotifier.shared

    private var model: AppModel { store.model }

    var body: some View {
        Form {
            Section {
                Toggle("Notify me about replies", isOn: enabledBinding)
                    .tint(Tokens.success)
                Text("A banner and a Dock badge whenever a bot replies in a chat you are not reading. A chat that is on screen never notifies — its own transcript has already said it.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                permissionRow
            } header: {
                Text("Replies")
            }

            if !model.bots.isEmpty {
                Section {
                    ForEach(model.bots) { bot in
                        Toggle(bot.displayName, isOn: muteBinding(bot.id))
                            .tint(Tokens.success)
                            .disabled(!model.replyNotificationsEnabled)
                    }
                } header: {
                    Text("Quiet these bots")
                } footer: {
                    Text("A quieted bot still counts on its row and in the badge; it just never raises a banner.")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .onAppear { notifier.refreshAuthorization() }
    }

    // MARK: Rows

    /// What the system says, said plainly. A denied permission is the one state where the app
    /// itself cannot fix anything, so the row carries the door out to the place that can.
    @ViewBuilder
    private var permissionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: permissionSymbol)
                .foregroundStyle(permissionTint)
            Text(permissionText)
                .foregroundStyle(Tokens.textPrimary)

            Spacer(minLength: 8)

            switch notifier.authorization {
            case .notDetermined:
                TextButton("Ask now", tone: Tokens.accentText) {
                    notifier.requestAuthorizationIfNeeded()
                }
            case .denied:
                TextButton("Open System Settings", tone: Tokens.accentText) {
                    openSystemNotificationSettings()
                }
            default:
                EmptyView()
            }
        }
        .font(TypeScale.font(TypeScale.label))

        if let error = notifier.deliveryError {
            Text(error)
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionSymbol: String {
        switch notifier.authorization {
        case .authorized, .provisional: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.triangle.fill"
        default: return "questionmark.circle"
        }
    }

    private var permissionTint: Color {
        switch notifier.authorization {
        case .authorized, .provisional: return Tokens.success
        case .denied: return Tokens.danger
        default: return Tokens.textMuted
        }
    }

    private var permissionText: String {
        switch notifier.authorization {
        case .authorized, .provisional: return "Allowed by macOS"
        case .denied: return "Turned off in System Settings"
        case .ephemeral: return "Allowed for now"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    // MARK: Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.replyNotificationsEnabled },
                set: { model.setReplyNotifications(enabled: $0) })
    }

    private func muteBinding(_ botID: String) -> Binding<Bool> {
        Binding(get: { !model.isNotificationMuted(botID) },
                set: { wantsBanners in
                    if wantsBanners == model.isNotificationMuted(botID) {
                        model.toggleNotificationMute(botID)
                    }
                })
    }

    private func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
