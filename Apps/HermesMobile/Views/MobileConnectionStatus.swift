import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

extension AppModel.Connection {
    /// The chip and the banner both talk `TransportState`; the app's model has its own
    /// five-case vocabulary. One mapping, so the two can never disagree about "offline".
    var transportState: TransportState {
        switch self {
        case .idle: return .idle
        case .connecting: return .connecting
        case .connected: return .open
        case .reconnecting(let attempt): return .reconnecting(attempt: attempt)
        case .failed(let why): return .failed(why)
        case .offline: return .closed(reason: "offline")
        }
    }
}

/// `direct · 34 ms` — transport and round-trip in one pill.
struct MobileConnectionPill: View {
    let connection: AppModel.Connection
    let rttMS: Int?

    var body: some View {
        StatusChip.transport(connection.transportState, path: .direct, rttMS: rttMS)
    }
}

extension View {
    /// The reconnect strip, as an inset rather than a modal: it never takes the screen,
    /// it scrolls with nothing, and it disappears the moment the socket is back.
    ///
    /// `ConnectionBanner.kind(for:)` returns nil for idle/connecting/open, so a healthy
    /// connection costs zero vertical space.
    func mobileConnectionBanner(connection: AppModel.Connection,
                                turnRunning: Bool,
                                host: String,
                                retry: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if let kind = ConnectionBanner.kind(for: connection.transportState) {
                ConnectionBanner(kind,
                                 host: host,
                                 turnRunning: turnRunning,
                                 onRetry: retry)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.press, value: connection.transportState)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Connection pills") {
    VStack(alignment: .leading, spacing: 14) {
        MobileConnectionPill(connection: .connected, rttMS: 34)
        MobileConnectionPill(connection: .connecting, rttMS: nil)
        MobileConnectionPill(connection: .reconnecting(attempt: 2), rttMS: nil)
        MobileConnectionPill(connection: .offline, rttMS: nil)
        MobileConnectionPill(connection: .failed("host unreachable"), rttMS: nil)
    }
    .padding(20)
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
#endif

#if DEBUG
#Preview("Connection banner inset") {
    ScrollView {
        Text("Transcript")
            .foregroundStyle(Tokens.textMuted)
            .frame(maxWidth: .infinity)
            .padding(40)
    }
    .mobileConnectionBanner(connection: .reconnecting(attempt: 2),
                            turnRunning: true,
                            host: "hermes.example.ts.net",
                            retry: {})
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
#endif
