import SwiftUI

/// Banners while the app is shut — the one setting, and the button that proves it works.
///
/// This is not APNs. Push to a sideloaded app needs a credential for the team that signed it, and
/// the certificate this build is signed with belongs to a resale team that hands out entitlements
/// but never its key. So delivery goes through an app that already has one: **Bark**, free on the
/// App Store, with a server we run. The host posts to it and Bark draws the banner.
///
/// What a person does: install Bark, copy the URL it shows, paste it here. That is the whole setup,
/// and the switch is per device because the URL is.
public struct PushRelaySettings: View {
    /// Hands the URL to the host, which keeps it per device.
    public var register: (String) async throws -> Void
    /// One banner, now.
    public var sendTest: () async throws -> Void

    @AppStorage(PushRelay.urlKey) private var storedURL = ""
    @State private var draft = ""
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var message: String?
    @State private var isError = false

    public init(register: @escaping (String) async throws -> Void,
                sendTest: @escaping () async throws -> Void) {
        self.register = register
        self.sendTest = sendTest
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("http://your-host:8081/your-key", text: $draft,
                      prompt: Text("http://your-host:8081/your-key")
                        .foregroundColor(Tokens.textPlaceholder))
                .textFieldStyle(.plain)
                .font(TypeScale.font(TypeScale.sm, design: .monospaced))
                .foregroundStyle(Tokens.textPrimary)
                .tint(Tokens.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                    .fill(Tokens.control))
                .overlay(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                    .strokeBorder(Tokens.borderStrong, lineWidth: 1))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .accessibilityIdentifier("pushRelayURL")

            HStack(spacing: 8) {
                OpenBotButton(isSaving ? "Saving…" : "Save",
                              kind: .secondary,
                              size: .small,
                              isDisabled: isSaving || draft.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await save() }
                }
                OpenBotButton(isTesting ? "Sending…" : "Send a test",
                              kind: .secondary,
                              size: .small,
                              isDisabled: isTesting || storedURL.isEmpty) {
                    Task { await test() }
                }
                if let message {
                    Text(message)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(isError ? Tokens.danger : Tokens.textMuted)
                        .lineLimit(2)
                }
            }

            Text("Install **Bark** (free, App Store), open its settings, copy the URL it shows and "
                 + "paste it here. The host sends a banner when a bot replies in a chat you are not "
                 + "reading — that is what makes notifications work with the app closed.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { draft = storedURL }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await register(draft.trimmingCharacters(in: .whitespacesAndNewlines))
            storedURL = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            message = "Registered."
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        do {
            try await sendTest()
            message = "Sent — check your lock screen."
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }
}

/// Where the relay URL is remembered on this device. One key, one meaning.
public enum PushRelay {
    public static let urlKey = "hermey.pushRelayURL"
}
