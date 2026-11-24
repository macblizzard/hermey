import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// Pair another device **from this one**: a QR and the link behind it, minted by the host on this
/// device's say-so.
///
/// Before this, a pairing code could only come from a process on the host (`hermey pair`). That made
/// "pair my desktop from my phone" a walk to the host, which is what was asked to go away (2026-11-17:
/// "generate a qr code and url on both devices to pair another device from that").
///
/// The invite is single-use and short-lived — the host's own rules, not this sheet's — so the sheet
/// shows the countdown, regenerates on demand, and says plainly that a code shown once is spent once.
/// The other side needs nothing new: both apps already parse `hermes://pair?host=…&code=…`.
struct PairAnotherDeviceSheet: View {
    @ObservedObject var model: AppModel

    @Environment(\.dismiss) private var dismiss

    @State private var invite: PairingInvite?
    @State private var error: String?
    @State private var busy = false
    @State private var countdown: Int = 0
    @State private var timer: Timer?

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section {
                        Text(error)
                            .font(TypeScale.font(TypeScale.sm))
                            .foregroundStyle(Tokens.danger)
                    }
                }

                Section {
                    if let invite {
                        VStack(spacing: 14) {
                            QRCodeView(content: invite.url, side: 200)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: Tokens.radiusGrouped,
                                                     style: .continuous)
                                        .fill(.white))

                            VStack(spacing: 4) {
                                Text("Scan with the other device's camera")
                                    .font(TypeScale.font(TypeScale.sm, weight: .medium))
                                    .foregroundStyle(Tokens.textPrimary)
                                Text("Or paste the link into that device's pairing sheet.")
                                    .font(TypeScale.font(TypeScale.caption))
                                    .foregroundStyle(Tokens.textMuted)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    } else if error == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Asking the host for a pairing code…")
                                .font(TypeScale.font(TypeScale.sm))
                                .foregroundStyle(Tokens.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                if let invite {
                    Section("Link") {
                        Text(invite.url)
                            .font(Tokens.mono)
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = invite.url
                        } label: {
                            Label("Copy link", systemImage: "doc.on.doc")
                        }
                        .hermeyFocusQuiet()
                    }

                    Section {
                        Button {
                            Task { await mint() }
                        } label: {
                            Label("Generate a new code", systemImage: "arrow.clockwise")
                        }
                        .disabled(busy)
                        .hermeyFocusQuiet()
                    } footer: {
                        Text(countdownFooter(invite))
                            .font(TypeScale.font(TypeScale.label))
                    }
                }

                Section {
                    Text("The code is single-use and expires when the countdown ends. Anyone who scans it pairs a device with full access to this host — show it to nobody but the device you are pairing.")
                        .font(TypeScale.font(TypeScale.label))
                        .foregroundStyle(Tokens.textMuted)
                }
            }
            .navigationTitle("Pair another device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                    .hermeyFocusQuiet()
                }
            }
            .task { await mint() }
            .onDisappear { timer?.invalidate() }
        }
    }

    private func countdownFooter(_ invite: PairingInvite) -> String {
        if countdown <= 0 {
            return "This code has expired — generate a new one."
        }
        let minutes = countdown / 60
        let seconds = countdown % 60
        return "Expires in \(minutes):\(seconds < 10 ? "0\(seconds)" : "\(seconds)")."
    }

    /// The host answers `expires_at` as an epoch; the countdown is against this device's clock, which is
    /// why the sheet starts the timer from the moment the answer lands rather than trusting a duration.
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
