import HermesAppKit
import OpenBotUI
import SwiftUI

/// Pair this Mac with a Hermes host: a `wss://` URL and the device token.
///
/// The sheet validates locally (`PairingAddress.parse`) and only then persists — and the
/// socket opens on the Pair press, never at launch. The token goes to the keychain; the URL
/// to `UserDefaults`. If the keychain refuses, the pairing still works for this run and the
/// footer says so rather than implying it was remembered.
struct PairHostSheet: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var deviceID = ""
    @State private var token = ""
    @State private var errorText: String?
    @State private var isConnecting = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case url
        case device
        case token
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            fields
            Hairline()
            footer
        }
        .frame(width: 500)
        .background(Tokens.sheet)
        .onAppear {
            if url.isEmpty {
                url = store.pairing?.baseURL ?? ""
            }
            if deviceID.isEmpty {
                deviceID = store.pairing?.deviceID ?? ""
            }
            focus = .url
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pair a host")
                .font(TypeScale.font(Tokens.textXL, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)

            Text("Hermey talks to your own host over its WebSocket relay. Nothing is sent until you press Pair.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 1) {
                insetField(title: "WebSocket URL",
                           placeholder: "wss://hermes.example.ts.net",
                           text: $url,
                           field: .url)
                Hairline(color: Tokens.borderGrouped)
                insetField(title: "Device ID",
                           placeholder: "from pair/claim — leave empty for a one-shot ticket",
                           text: $deviceID,
                           field: .device)
                Hairline(color: Tokens.borderGrouped)
                insetField(title: "Device token",
                           placeholder: "refresh token from pair/claim",
                           text: $token,
                           field: .token)
            }
            .groupedSurface()

            if let errorText {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.danger)
                    Text(errorText)
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(footnote)
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)

            if let pairing = store.pairing {
                HStack(spacing: 6) {
                    Text("Currently paired with \(pairing.displayHost).")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textDim)
                    Spacer(minLength: 6)
                    TextButton("Unpair", tone: Tokens.danger) {
                        Task {
                            await store.unpair()
                            dismiss()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func insetField(title: String,
                            placeholder: String,
                            text: Binding<String>,
                            field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(Tokens.textGroupedSecondary)

            TextField("",
                      text: text,
                      prompt: Text(placeholder).foregroundColor(Tokens.textPlaceholder))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Tokens.textPrimary)
                .tint(Tokens.accent)
                .focused($focus, equals: field)
                .onSubmit {
                    switch field {
                    case .url: focus = .device
                    case .device: focus = .token
                    case .token: submit()
                    }
                }
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footnote: String {
        if store.pairingIsSessionOnly {
            return "The login keychain refused the pairing, so it lasts until you quit. Paste it again next launch."
        }
        if deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "With no device ID the token is used as a one-shot socket ticket: the relay burns it on the first connection. Keep the pairing in the login keychain either way."
        }
        return "The app mints a fresh 30 s socket ticket from this refresh token each time it connects, so a reconnect does not need a new paste. The pairing is stored in your login keychain."
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("⌘↩ pairs")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)

            Spacer(minLength: 0)

            OpenBotButton("Cancel", kind: .ghost) {
                dismiss()
            }

            OpenBotButton("Pair",
                          systemImage: "link",
                          kind: .primary,
                          isBusy: isConnecting,
                          action: submit)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Pairing

    private func submit() {
        guard !isConnecting else { return }
        errorText = nil
        do {
            try store.pair(urlText: url, deviceID: deviceID, token: token)
        } catch let pairingError as PairingError {
            errorText = pairingError.errorDescription
            return
        } catch {
            errorText = error.localizedDescription
            return
        }

        isConnecting = true
        Task {
            await store.connect()
            isConnecting = false
            dismiss()
        }
    }
}

// MARK: - Previews

private struct PairHostSheetPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        PairHostSheet(store: store)
            .padding(30)
            .background(Tokens.canvas)
            .preferredColorScheme(.dark)
    }
}

private struct PairHostSheetPairedPreview: View {
    @StateObject private var store = WorkspaceStore(model: PreviewWorkspace.model(),
                                                    pairing: PreviewWorkspace.address)

    var body: some View {
        PairHostSheet(store: store)
            .padding(30)
            .background(Tokens.canvas)
            .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Pair host") {
    PairHostSheetPreview()
}
#endif

#if DEBUG
#Preview("Pair host · already paired") {
    PairHostSheetPairedPreview()
}
#endif
