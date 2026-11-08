import HermesAppKit
import HermesKit

extension AppModel.Connection {
    /// The wire state this shell state maps to, for `StatusChip.transport`.
    ///
    /// `AppModel.Connection` is the app's vocabulary ("not connected", "direct"); the chip
    /// speaks `TransportState`. One mapping, so the sidebar chip and the context panel can
    /// never disagree about the same socket.
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

    /// The one-line explanation under the host name.
    var detail: String {
        switch self {
        case .idle: return "not connected"
        case .connecting: return "opening the socket"
        case .connected: return "live over the tailnet"
        case .reconnecting(let attempt): return "reconnecting · attempt \(attempt)"
        case .failed(let why): return why
        case .offline: return "offline"
        }
    }
}
