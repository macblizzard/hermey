import Foundation

/// Encodes the byte-only subset of the gateway's attachment RPCs. The caller must
/// use the existing authenticated websocket and its runtime session identifier.
struct AttachmentPayload {
    /// One source of truth for the client-side ceiling: `AttachmentBudget.maximumBytes`
    /// (8 MiB, which encodes to ~10.7 MiB and therefore fits one 16 MiB websocket frame).
    /// `HermesAppKit.AppModel.maxAttachmentBytes` and
    /// `HermesKit.GatewayClientActor.maxAttachmentBytes` mirror the same number; they are
    /// separate literals only because those modules cannot import the app's sources.
    static let maximumBytes = AttachmentBudget.maximumBytes
    let name: String
    let data: Data
    let isImage: Bool

    enum Failure: LocalizedError {
        case empty, tooLarge, invalidName, invalidResponse
        var errorDescription: String? {
            switch self {
            case .empty:
                return AttachmentBudgetError.empty.errorDescription
            case .tooLarge:
                return AttachmentBudgetError.tooLarge(byteCount: 0,
                                                      maximumBytes: AttachmentBudget.maximumBytes).errorDescription
            case .invalidName:
                return AttachmentBudgetError.invalidName.errorDescription
            case .invalidResponse:
                return "The host did not confirm the attachment."
            }
        }
    }

    func request(sessionID: String) throws -> (method: String, params: [String: String]) {
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        // Same rule the host enforces, and the same one the file path applies on the way in,
        // so a name that reaches here unmodified is already sendable.
        guard AttachmentName.sanitized(name) == name else { throw Failure.invalidName }
        let encoded = data.base64EncodedString()
        if isImage {
            return ("image.attach_bytes", ["session_id": sessionID, "filename": name, "content_base64": encoded])
        }
        return ("file.attach", ["session_id": sessionID, "name": name,
                                "data_url": "data:application/octet-stream;base64," + encoded])
    }

    /// `file.attach` returns an @file reference; it must be included in the next
    /// prompt. Images are queued by the gateway and do not need a reference.
    static func reference(from result: [String: Any], isImage: Bool) throws -> String? {
        guard result["attached"] as? Bool == true else { throw Failure.invalidResponse }
        if isImage { return nil }
        guard let ref = result["ref_text"] as? String, !ref.isEmpty else { throw Failure.invalidResponse }
        return ref
    }
}
