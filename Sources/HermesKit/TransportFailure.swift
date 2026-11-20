import Foundation

/// Which failures mean "there was no wire" rather than "the host answered and refused".
///
/// The distinction is load-bearing in exactly one place: a `session.resume` that died because the
/// socket was gone is worth one silent retry on a fresh connection (`AppModel.openStoredConversation`),
/// while a resume the host refused — `4001`/`4007`, "this id no longer exists" — must never be papered
/// over with a new empty conversation.
///
/// It cannot be decided from `localizedDescription`: the same abort arrives as a `GatewayError`, an
/// `NSError` in `NSURLErrorDomain`, or a POSIX `ECONNABORTED` ("Software caused connection abort"),
/// depending on which layer noticed the socket die first.
public enum TransportFailure {

    /// True for the family of errors that say the connection failed, timed out or went away.
    public static func isTransport(_ error: Error) -> Bool {
        if let gateway = error as? GatewayError {
            switch gateway {
            case .notConnected, .handshakeTimedOut, .transportClosed(_), .timeout(_, _):
                return true
            // The host answered. An RPC refusal, a shape mismatch and a cancellation are all
            // decisions, not a lost wire — retrying them would only repeat the answer.
            case .rpc(_), .malformedResponse(_), .cancelled,
                 .needsEmptyTranscriptConfirmation(_), .needsDeepCutConfirmation(_):
                return false
            }
        }
        if let transport = error as? TransportError {
            switch transport {
            case .notConnected: return true
            // A URL this app cannot dial stays undiallable; a retry would just say so again.
            case .badURL(_): return false
            }
        }
        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain:
            // `networkConnectionLost` is ECONNABORTED one layer up on iOS, and it is the one that
            // reaches the user as "Software caused connection abort".
            return [
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost,
                NSURLErrorDNSLookupFailed,
            ].contains(ns.code)
        case NSPOSIXErrorDomain:
            // ECONNABORTED / ECONNRESET / ETIMEDOUT
            return ns.code == 53 || ns.code == 54 || ns.code == 60
        default:
            return false
        }
    }
}
