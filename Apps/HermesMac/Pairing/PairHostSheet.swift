import HermesAppKit
import OpenBotUI
import SwiftUI

/// Pair this Mac with a Hermes host.
///
/// One field, because there is one thing to hand over: the code. Paste the eight digits from
/// `hermey pair` — or the whole `hermes://pair?…` link, which is easier to move from a phone to a Mac
/// — and press Pair. The app redeems the code, receives its own device row, and mints a fresh 30 s
/// socket ticket on every connection from then on.
///
/// The three manual fields the sheet used to open with are still here, behind **Advanced**, for the
/// one case that needs them: a hand-issued token with no code to redeem. They are no longer the front
/// door — a person who has never paired has no idea what a "refresh token from pair/claim" is, and,
/// until this sheet learned to claim, a code from `hermey pair` could not be used on this platform at
/// all.
///
/// The token goes to the keychain; the address to `UserDefaults`. If the keychain refuses, the pairing
/// still works for this run and the footer says so rather than implying it was remembered.
struct PairHostSheet: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    /// The code, or the whole `hermes://` link.
    @State private var code = ""
    /// The manual path, kept out of sight until asked for.
    @State private var showAdvanced = false
    @State private var url = ""
    @State private var deviceID = ""
    @State private var token = ""

    @State private var errorText: String?
    @State private var isConnecting = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case code
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
            showAdvanced = false
            focus = .code
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pair a host")
                .font(TypeScale.font(Tokens.textXL, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)

            Text(pairedHostHint)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var pairedHostHint: String {
        if let host = store.pairing?.displayHost {
            return "Paste the code your host prints with `hermey pair` — or the whole hermes:// link. Previously paired with \(host)."
        }
        return "Paste the whole hermes:// link from `hermey pair`. Only have the code? Plant the host's address under Advanced first — the digits do not say which host is waiting for them."
    }

    // MARK: Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 1) {
                insetField(title: "Pairing code or link",
                           placeholder: "12345678  ·  hermes://pair?host=…&code=…",
                           text: $code,
                           field: .code)
            }
            .groupedSurface()

            Text("Eight digits, or the link your host gave you — single use, ten minutes.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)

            advanced

            if let errorText {
                HStack(alignment: .top, spacing: 6) {
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

    /// The manual path, folded away. A disclosure rather than a second tab: one extra click for the
    /// rare case, no decisions in the common one.
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    Text("Advanced — I have a device token")
                        .font(TypeScale.font(TypeScale.caption))
                }
                .foregroundStyle(Tokens.textMuted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
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
                .transition(.opacity)
            }
        }
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
                    case .code: submit()
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
        if showAdvanced, !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The app mints a fresh 30 s socket ticket from this refresh token each time it connects, so a reconnect does not need a new paste. The pairing is stored in your login keychain."
        }
        return "The pairing is stored in your login keychain. Nothing is sent until you press Pair."
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

        // A code, pasted as digits or as the whole link. The host comes from the link, then from an
        // address typed under Advanced, then from the host this Mac was last paired with — and a
        // *code with no address anywhere* is half a pairing, not a bad code. This Mac used to call
        // it invalid and never send it, which made `hermey pair`'s digits useless on a fresh
        // install.
        let typedHost = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let rememberedHost = store.pairing?.baseURL
        let fallbackHost = typedHost.isEmpty ? rememberedHost : typedHost

        switch PairingLink.classify(code, defaultHost: fallbackHost) {
        case .link(let link):
            pair(with: link)
            return
        case .codeNeedingHost(let digits):
            // Keep the digits — the code is spent only when it is claimed — and ask for the half
            // that is missing.
            code = digits
            if !showAdvanced {
                showAdvanced = true
            }
            focus = .url
            // The digits are kept and the address field is opened: half a pairing is not an error,
            // it is the next question.
            errorText = "That code is fine — it needs the address of the host that printed it. Paste it above (for example https://name.ts.net:8443), then press Pair again."
            return
        case .unusable:
            break
        }

        if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorText = rememberedHost == nil
                ? "That is not a pairing code. Paste the whole hermes:// link, or open Advanced and enter the host address."
                : "That is not a pairing code or a hermes:// link."
            return
        }

        // No code: the manual path, unchanged.
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "Paste a pairing code to pair."
            return
        }
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

    /// Redeem the code, then store what comes back. The claim spends the code, so a failure after it
    /// must say what happened rather than sending the user back to paste a code that no longer works.
    private func pair(with link: PairingLink) {
        isConnecting = true
        code = ""
        Task {
            do {
                let claim = try await PairingClaim.claim(code: link.code,
                                                         host: link.httpBase,
                                                         deviceName: Self.deviceName)
                try store.pair(urlText: link.websocketBase,
                               deviceID: claim.deviceID,
                               token: claim.refreshToken)
                await store.connect()
                isConnecting = false
                dismiss()
            } catch {
                isConnecting = false
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private static var deviceName: String {
        let name = Host.current().localizedName ?? "Mac"
        return String(name.prefix(40))
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
