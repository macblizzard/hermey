import SwiftUI
import OpenBotUI

/// Pairing: the QR the host shows, or the digits it prints.
///
/// The camera is an enhancement, never a requirement — the paste field is always there,
/// and on a device with no camera the sheet reads as if the scanner had never been
/// offered. Claiming is `AppEnvironment.pair`, which is the only thing that touches the
/// bridge; this view owns text and focus and nothing else.
///
/// NOTE(project): the scanner needs `NSCameraUsageDescription` in the target's
/// Info.plist (`project.yml` → `targets.HermesMobile.info.properties`). iOS terminates
/// an app that creates a capture input without it; paste-only keeps working on devices
/// where the key is absent *and* no camera exists.
struct PairingSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var host = ""
    @State private var scannerMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    scanner
                    codeEntry
                    if let message = scannerMessage {
                        Text(message)
                            .font(TypeScale.font(TypeScale.label))
                            .foregroundStyle(Tokens.textGroupedSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = app.pairingError {
                        errorRow(error)
                    }
                    actions
                    footnote
                }
                .padding(16)
            }
            .background(Tokens.canvas)
            .navigationTitle("Pair a device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.textMuted)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if host.isEmpty { host = app.store.host?.host ?? "" }
            app.dismissPairingError()
        }
    }

    // MARK: Scanner

    @ViewBuilder
    private var scanner: some View {
        #if canImport(AVFoundation) && os(iOS)
        if QRScannerView.isCameraAvailable {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous)
                        .fill(Tokens.sheetInset)
                    QRScannerView { value in
                        absorb(value)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous))
                }
                .frame(height: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous)
                        .strokeBorder(Tokens.borderGrouped, lineWidth: 1)
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Camera viewfinder for the pairing QR code")

                Text("Point the camera at the code on your host.")
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textGroupedSecondary)
            }
        } else {
            unavailableScanner
        }
        #else
        unavailableScanner
        #endif
    }

    private var unavailableScanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera")
                .font(.system(size: 14))
                .foregroundStyle(Tokens.textDim)
            Text("No camera here — enter the code below.")
                .font(TypeScale.font(TypeScale.md))
                .foregroundStyle(Tokens.textMuted)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .fill(Tokens.sheet)
        )
    }

    // MARK: Entry

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption("PAIRING CODE", color: Tokens.textGroupedSecondary)

            TextField("12345678", text: $code)
                .font(.system(.title2, design: .monospaced, weight: .semibold))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .foregroundStyle(Tokens.textPrimary)
                .tint(Tokens.accent)
                .padding(.horizontal, 12)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .fill(Tokens.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                )
                .accessibilityLabel("Pairing code")

            SectionCaption("HOST", color: Tokens.textGroupedSecondary)
                .padding(.top, 4)

            TextField("hermes.example.ts.net", text: $host)
                .font(TypeScale.font(TypeScale.lg))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Tokens.textPrimary)
                .tint(Tokens.accent)
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .fill(Tokens.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                )
                .accessibilityLabel("Host address")
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.danger)
            Text(message)
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .fill(Tokens.dangerSoft)
        )
    }

    private var actions: some View {
        OpenBotButton("Pair this phone",
                      systemImage: "link",
                      kind: .primary,
                      isDisabled: !canPair || app.isPairing,
                      isBusy: app.isPairing) {
            submit()
        }
    }

    private var footnote: some View {
        Text("The code is single use and expires two minutes after the host prints it. This phone keeps an Ed25519 key in the Keychain and a refresh token the host can revoke at any time.")
            .font(TypeScale.font(TypeScale.label))
            .foregroundStyle(Tokens.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    private var canPair: Bool {
        PairingPayload.normalizeCode(code) != nil
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A scanned payload can carry the host with the code; a bare code keeps whatever the
    /// user typed (or the host already paired).
    private func absorb(_ raw: String) {
        guard let payload = PairingPayload.parse(raw) else {
            scannerMessage = "That code did not contain a pairing code. Use the digits under the QR."
            return
        }
        code = payload.code
        if let scannedHost = payload.host, !scannedHost.isEmpty {
            host = PairedHost.displayHost(from: scannedHost)
        }
        scannerMessage = "Scanned \(payload.code). Check the host, then pair."
        Haptics.selection()
    }

    private func submit() {
        Task {
            let paired = await app.pair(code: code,
                                        host: host,
                                        deviceName: app.defaultDeviceName)
            if paired { dismiss() }
        }
    }
}

// MARK: - Previews

#if DEBUG
#if DEBUG
#Preview("Pairing sheet") {
    let environment = AppEnvironment.preview(paired: false)
    Tokens.canvas
        .sheet(isPresented: .constant(true)) {
            PairingSheet()
                .environmentObject(environment)
        }
        .preferredColorScheme(.dark)
}
#endif
#endif
