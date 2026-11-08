import Foundation

/// The bridge's voice payloads are not frozen. Inject the final HTTP implementation;
/// do not send audio to the host-machine microphone RPC or invent a transcript.
/// Each implementation must obtain a fresh single-use ticket for each HTTPS request,
/// use it as an Authorization bearer, reject redirects, and never log credentials/audio.
struct VoiceTransport {
    /// Recorded audio bytes plus the container's mime type (`audio/mp4` for the AAC
    /// file `VoiceController` writes). Returns the actual recognized text.
    var transcribe: (Data, String) async throws -> String
    /// Returns audio bytes in a format AVAudioPlayer supports (mp3 from the bridge).
    var synthesize: (String) async throws -> Data

    static let unavailable = VoiceTransport(
        transcribe: { _, _ in throw VoiceTransportError.unavailable },
        synthesize: { _ in throw VoiceTransportError.unavailable }
    )
}

/// Every failure the transport may surface. The message is what the user reads, so it
/// says what happened and what to do — never a credential, a URL or a raw response body.
enum VoiceTransportError: LocalizedError, Equatable {
    case unavailable
    case emptyTranscript
    case emptyAudio
    case emptyText
    case unauthorized
    case tooLarge
    case unsupportedAudio
    case textTooLong
    /// The host's own one-line reason for a provider failure (already redacted server-side).
    case providerUnavailable(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Voice is unavailable: the paired host's voice service is not configured."
        case .emptyTranscript:
            return "The voice service returned an empty transcript."
        case .emptyAudio:
            return "The voice service returned no audio."
        case .emptyText:
            return "There is nothing to speak."
        case .unauthorized:
            return "The host did not accept this request. Check the pairing and try again."
        case .tooLarge:
            return "That recording is too large to send. Keep voice messages under 60 seconds."
        case .unsupportedAudio:
            return "The host does not accept this audio format."
        case .textTooLong:
            return "That reply is too long to speak."
        case .providerUnavailable(let message):
            return message.isEmpty ? "The host's voice service is unavailable right now." : message
        case .malformedResponse:
            return "The host sent a voice response this app does not understand."
        }
    }
}
