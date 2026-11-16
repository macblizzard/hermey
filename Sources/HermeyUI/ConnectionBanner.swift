import SwiftUI
import HermesKit

/// The strip that says the wire is not healthy.
///
/// It sits in a `safeAreaInset`, so it is edge to edge with hairline rules and no corner
/// radius. The copy is the spec's: it says what happened *and* what is still true —
/// "the turn is still running" is the difference between a scare and a status line. It
/// always carries a way out (`Retry`) or a reason there is none.
public struct ConnectionBanner: View {
    public enum Kind: Equatable {
        case reconnecting(attempt: Int)
        case offline
        case protocolMismatch(server: String, client: String)
    }

    private let kind: Kind
    private let host: String
    private let turnRunning: Bool
    private let onRetry: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    public init(_ kind: Kind,
                host: String = "hermes",
                turnRunning: Bool = false,
                onRetry: (() -> Void)? = nil) {
        self.kind = kind
        self.host = host
        self.turnRunning = turnRunning
        self.onRetry = onRetry
    }

    /// A banner is only for a wire that is not open; `.open` and `.idle` map to nothing.
    public static func kind(for state: TransportState) -> Kind? {
        switch state {
        case .reconnecting(let attempt): return .reconnecting(attempt: attempt)
        case .closed(_), .failed(_): return .offline
        case .open, .connecting, .idle: return nil
        }
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 0.35 : 1)

            Text(message)
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let onRetry {
                TextButton("Retry", tone: Tokens.accentText, action: onRetry)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tintSoft)
        .overlay(alignment: .bottom) { Hairline(color: Tokens.borderStrong) }
        .onAppear {
            guard isReconnecting, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: Copy

    var message: String {
        switch kind {
        case .reconnecting(let attempt):
            if turnRunning {
                return "Reconnecting — the turn is still running on \(host)."
            }
            return attempt > 1
                ? "Reconnecting to \(host) — attempt \(attempt)."
                : "Reconnecting to \(host)…"

        case .offline:
            return turnRunning
                ? "Offline — the turn is still running on \(host). Your next message queues."
                : "Offline — check that \(host) is reachable on the tailnet."

        case .protocolMismatch(let server, let client):
            return "Update the app — \(host) speaks protocol \(server), this build expects \(client)."
        }
    }

    private var isReconnecting: Bool {
        if case .reconnecting = kind { return true }
        return false
    }

    private var tint: Color {
        switch kind {
        case .reconnecting: return Tokens.warning
        case .offline: return Tokens.danger
        case .protocolMismatch: return Tokens.warning
        }
    }

    private var tintSoft: Color {
        switch kind {
        case .reconnecting: return Tokens.warningSoft
        case .offline: return Tokens.dangerSoft
        case .protocolMismatch: return Tokens.warningSoft
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Connection banner") {
    VStack(spacing: 0) {
        ConnectionBanner(.reconnecting(attempt: 2), host: "hermes", turnRunning: true, onRetry: {})
        ConnectionBanner(.reconnecting(attempt: 1), host: "hermes")
        ConnectionBanner(.offline, host: "hermes", turnRunning: true, onRetry: {})
        ConnectionBanner(.offline, host: "hermes")
        ConnectionBanner(.protocolMismatch(server: "3", client: "2"), host: "hermes")
        Spacer()
    }
    .frame(width: 520, height: 320, alignment: .top)
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
#endif
