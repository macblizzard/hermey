import Foundation

/// Reading a failure the way the person in front of the screen needs it.
///
/// Two rules, both learned from a support report that showed a raw `NSError` dump under the pane:
///
/// * **A cancelled request is not a failure.** SwiftUI tears a `.task` down when a view goes away or
///   when its id changes, which cancels any request in flight; `-999 cancelled` then reached the
///   error strip and the user was told their host was broken while it was answering fine.
/// * **Nobody reads `NSURLErrorDomain Code=-999`.** A short sentence with the thing that failed is
///   the most a strip can carry.
public enum RequestOutcome {
    /// True when the error only means "this request was superseded or the view went away".
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// A sentence for the error strip, or nil when there is nothing worth saying (a cancellation).
    public static func describe(_ error: Error) -> String? {
        if isCancellation(error) { return nil }
        if let urlError = error as? URLError {
            let host = urlError.failingURL?.host.map { " to \($0)" } ?? ""
            switch urlError.code {
            case .timedOut: return "The host did not answer in time\(host)."
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                return "Cannot reach the host\(host) right now."
            case .notConnectedToInternet: return "This device is not on the network."
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return "The secure connection to the host\(host) failed."
            case .badServerResponse: return "The host answered with something unreadable."
            default: return "The request to the host\(host) failed (\(urlError.code.rawValue))."
            }
        }
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
    }
}
