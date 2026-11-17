import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// Pair another device **from the desktop**: the QR and link the desktop mints for a phone to scan,
/// or for anyone to paste into a pairing sheet.
///
/// The mirror of the phone's `PairAnotherDeviceSheet`, with the desktop's own controls: the invite is
/// the host's single-use ten-minute code, minted on this paired device's say-so, and the link is the
/// same `hermes://pair?host=…&code=…` shape every pairing surface here already parses.
struct MacPairAnotherSheet: View {
    @ObservedObject var model: AppModel

    @Environment(\.dismiss) private var dismiss

    @State private var invite: PairingInvite?
    @State private var error: String?
    @State private var busy = false
    @State private var countdown = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Hairline()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if let error {
                        Text(error)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let invite {
                        QRCodeView(content: invite.url, side: 200)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: Tokens.radiusGrouped,
                                                 style: .continuous)
                                    .fill(.white))
                            .frame(maxWidth: .infinity)

                        VStack(spacing: 4) {
                            Text("Scan with the other device's camera")
                                .font(TypeScale.font(Tokens.textSM, weight: .medium))
                                .foregroundStyle(Tokens.textPrimary)
                            Text("Or paste the link into that device's pairing sheet.")
                                .font(TypeScale.font(TypeScale.caption))
                                .foregroundStyle(Tokens.textMuted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 6) {
                            SectionCaption("LINK")
                            Text(invite.url)
                                .font(Tokens.mono)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HermeyButton("Copy link", systemImage: "doc.on.doc",
                                         kind: .secondary, size: .small) {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(invite.url, forType: .string)
                            }
                        }

                        HermeyButton("Generate a new code", systemImage: "arrow.clockwise",
                                     kind: .secondary, size: .small) {
                            Task { await mint() }
                        }
                        .disabled(busy)

                        Text(countdownFooter)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textDim)

                        Text("The code is single-use and expires when the countdown ends. Anyone who scans it pairs a device with full access to this host — show it to nobody but the device you are pairing.")
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if error == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Asking the host for a pairing code…")
                                .font(TypeScale.font(TypeScale.caption))
                                .foregroundStyle(Tokens.textMuted)
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 460)
        .frame(minHeight: 480, idealHeight: 560, maxHeight: 640)
        .background(Tokens.canvas)
        .task { await mint() }
        .onDisappear { timer?.invalidate() }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            SectionCaption("PAIR ANOTHER DEVICE")
            Spacer(minLength: 8)
            HermeyButton("Done", kind: .secondary, size: .small) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var countdownFooter: String {
        guard let invite else { return "" }
        if countdown <= 0 {
            return "This code has expired — generate a new one."
        }
        let seconds = countdown % 60
        return "Expires in \(countdown / 60):\(seconds < 10 ? "0\(seconds)" : "\(seconds)")."
    }

    private func mint() async {
        busy = true
        defer { busy = false }
        do {
            let fresh = try await model.makePairingInvite()
            invite = fresh
            error = nil
            restartCountdown(from: fresh.expiresIn)
        } catch {
            self.error = error.localizedDescription
            invite = nil
        }
    }

    private func restartCountdown(from serverEpoch: Int) {
        timer?.invalidate()
        countdown = max(0, serverEpoch - Int(Date().timeIntervalSince1970))
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            countdown = max(0, countdown - 1)
            if countdown == 0 { timer?.invalidate() }
        }
    }
}
