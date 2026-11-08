import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import AVFoundation
import Combine
import SwiftUI
#endif

// The first two sections are Foundation only: the wire contract and the request are
// decisions, not capture, so a harness can exercise them with no microphone and no host
// (the same shape as `Tests/MacDeviceManagementTests`, which compiles `MacDeviceService`
// on its own). Everything that touches AVFoundation lives under `#if os(macOS)` below.

// MARK: - Failures

/// Every failure voice input can surface. The message is what the user reads, so it says
/// what happened and what to do — never a credential, a URL or a raw response body.
enum MacVoiceFailure: LocalizedError, Equatable {
    /// The pairing has no refresh token, only a ticket that the socket already burned.
    case devicePairingRequired
    case notConfigured
    case unauthorized
    case tooLarge
    case unsupportedAudio
    case emptyRecording
    case emptyTranscript
    case malformedResponse
    /// The host's own one-line reason for a provider failure (already redacted there).
    case providerUnavailable(String)
    case unreachable(String)
    case microphonePermissionDenied
    case microphoneDescriptionMissing
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .devicePairingRequired:
            return "Voice input needs a device pairing. Pair this Mac with its device ID and token — a one-shot ticket is already spent."
        case .notConfigured:
            return "Voice is unavailable: this Mac is not connected to a paired host."
        case .unauthorized:
            return "The host did not accept the transcription request. Check the pairing and try again."
        case .tooLarge:
            return "That recording is too large to send. Keep voice messages under 60 seconds."
        case .unsupportedAudio:
            return "The host does not accept this audio format."
        case .emptyRecording:
            return "Nothing was recorded. Check the input device and try again."
        case .emptyTranscript:
            return "The host heard nothing in that recording."
        case .malformedResponse:
            return "The host sent a voice response this app does not understand."
        case .providerUnavailable(let message):
            return message.isEmpty ? "The host's voice service is unavailable right now." : message
        case .unreachable(let why):
            return "Could not reach the host to transcribe that recording (\(why))."
        case .microphonePermissionDenied:
            return "Microphone access is denied. Allow Hermes in System Settings ▸ Privacy & Security ▸ Microphone, then try again."
        case .microphoneDescriptionMissing:
            return "The microphone usage description is missing from the app configuration."
        case .recordingFailed(let why):
            return "Could not start recording: \(why)"
        }
    }
}

// MARK: - Wire contract

/// The bridge's `POST /v1/voice/transcribe`, as pure functions.
///
/// `Bridge/hermes_bridge/voice.py` (`create_voice_router`) takes
/// `{mime_type, content_base64}` and answers `{transcript}`; it refuses an unlisted container
/// with 415, an oversized body with 413, and a missing device ticket with 401. The mapping
/// below is that router's status table, so it can be checked without a microphone.
enum MacVoiceWire {
    /// The bridge's decoded-audio ceiling (`MAX_AUDIO_BYTES`).
    static let maxAudioBytes = 10 * 1024 * 1024
    /// `ALLOWED_AUDIO_MIME`: mp3, m4a, wav, ogg — nothing else.
    static let acceptedAudioMimeTypes: Set<String> = [
        "audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/wav", "audio/x-wav", "audio/ogg",
    ]
    /// What `AVAudioRecorder` writes here: AAC in an MP4 container, which the bridge lists
    /// as `audio/mp4` and the phone already sends.
    static let recordingMimeType = "audio/mp4"
    /// One minute, matching the phone. At 32 kbit/s that is ≈240 KB — far inside the 10 MiB
    /// ceiling, so the size limit is an abuse bound and never a UX bound.
    static let maxDuration: TimeInterval = 60

    /// Local mirrors of the host's limits: fail fast with a sentence to act on instead of
    /// uploading bytes the bridge would reject anyway.
    static func validate(audio: Data, mimeType: String) throws -> Data {
        guard acceptedAudioMimeTypes.contains(mimeType.lowercased()) else {
            throw MacVoiceFailure.unsupportedAudio
        }
        guard !audio.isEmpty else { throw MacVoiceFailure.emptyRecording }
        guard audio.count <= maxAudioBytes else { throw MacVoiceFailure.tooLarge }
        return audio
    }

    /// Bytes only. There is no URL, path or filename field, because the bridge forbids extras.
    static func requestBody(audio: Data, mimeType: String) throws -> Data {
        let body: [String: String] = [
            "mime_type": mimeType,
            "content_base64": audio.base64EncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// HTTP status + body → the transcript, or a typed failure. No network, no clock.
    ///
    /// A 2xx that is not `{transcript: …}` is `malformedResponse` rather than an empty
    /// success: a reverse proxy's HTML page must never read as "the host heard nothing".
    static func outcome(status: Int, body: Data) -> Result<String, MacVoiceFailure> {
        switch status {
        case 200..<300:
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let transcript = object["transcript"] as? String else {
                return .failure(.malformedResponse)
            }
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failure(.emptyTranscript) }
            return .success(text)
        case 401:
            return .failure(.unauthorized)
        case 413:
            return .failure(.tooLarge)
        case 415:
            return .failure(.unsupportedAudio)
        default:
            // FastAPI answers failures as `{"detail": "…"}`; those details are short fixed
            // sentences written by the bridge, never a provider body or a key.
            if let detail = detail(from: body) {
                return .failure(.providerUnavailable(String(detail.prefix(160))))
            }
            return .failure(.providerUnavailable("The host's voice service failed (HTTP \(status))."))
        }
    }

    static func detail(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let detail = object["detail"] as? String else { return nil }
        return detail
    }
}

// MARK: - Client

/// `POST /v1/voice/transcribe` on the paired bridge.
///
/// One request, one freshly minted single-use ticket, sent as an `Authorization` bearer
/// exactly like `MacDeviceService` and the phone's `VoiceService`: a ticket that opened the
/// socket is already spent, so a fresh one is minted per request from the device's refresh
/// token (`POST /v1/token`). Audio travels in the body only. Nothing is cached and nothing is
/// logged.
struct MacVoiceService {
    let address: PairingAddress
    var session: URLSession = .shared
    /// How a request authenticates. `nil` mints from the device's refresh token, which is the
    /// production path; a harness injects a counter here to prove every request gets its own
    /// ticket without a `/v1/token` round trip.
    var freshTicket: (() async throws -> String)?

    func transcribe(audio: Data, mimeType: String) async throws -> String {
        _ = try MacVoiceWire.validate(audio: audio, mimeType: mimeType)
        // A ticket-only pairing has no refresh token: its one ticket was burned by the socket
        // upgrade, so there is nothing left to authenticate a second request with.
        guard !address.isTicketOnly else { throw MacVoiceFailure.devicePairingRequired }

        let origin = try address.apiOrigin()
        let body = try MacVoiceWire.requestBody(audio: audio, mimeType: mimeType)
        let ticket: String
        if let mint = freshTicket {
            ticket = try await mint()
        } else {
            ticket = try await address.mintedTicket()
        }

        var request = URLRequest(url: origin.appendingPathComponent("v1/voice/transcribe"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(ticket)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MacVoiceFailure.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MacVoiceFailure.malformedResponse
        }
        // URLSession follows redirects on its own; a redirected answer means the reply did not
        // come from the host this Mac is paired with. Refuse it.
        guard Self.sameEndpoint(http.url, request.url) else {
            throw MacVoiceFailure.malformedResponse
        }
        switch MacVoiceWire.outcome(status: http.statusCode, body: data) {
        case .success(let transcript):
            return transcript
        case .failure(let failure):
            throw failure
        }
    }

    private static func sameEndpoint(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs,
              let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else {
            return false
        }
        return left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased()
            && left.path == right.path
    }
}

// MARK: - Capture

#if os(macOS)

/// Owns one microphone capture on the Mac: permission, a temporary AAC file, and exactly one
/// transcription request.
///
/// The controller never sends a message. A transcript goes to `transcriptSink`, which the
/// composer appends to the draft, so misrecognition is read before it leaves the Mac.
///
/// `AVAudioRecorder` (not `AVAudioEngine`) because the bridge wants a container, not samples,
/// and the same AAC settings the phone uses are known to transcribe well. There is no
/// `AVAudioSession` on the Mac: the default input device is whatever System Settings says.
@MainActor
final class MacVoiceController: ObservableObject {
    enum State: Equatable { case idle, requestingPermission, recording, transcribing }

    @Published private(set) var state: State = .idle
    @Published private(set) var errorMessage: String?

    /// Injected by the window, so a test or a preview can answer without a host. The default
    /// reports itself instead of inventing a transcript. `@MainActor` because the closures the
    /// composer supplies read and write `AppModel`'s draft.
    var transcribe: @MainActor (Data, String) async throws -> String = { _, _ in
        throw MacVoiceFailure.notConfigured
    }
    /// Where a finished transcript goes. Set by the composer; never called with empty text.
    var transcriptSink: (@MainActor (String) -> Void)?

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var operation: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    /// Bumped by `cancel()`: a request that lands after the user left must not write to a
    /// draft that is no longer theirs.
    private var generation = UUID()

    /// True while a second tap would be ignored anyway (permission, upload).
    var isBusy: Bool { state == .requestingPermission || state == .transcribing }
    var isRecording: Bool { state == .recording }

    deinit {
        operation?.cancel()
        limitTask?.cancel()
        recorder?.stop()
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Start

    /// Ask for the microphone, then start writing a temporary file. A second tap while a
    /// capture is running is ignored: the button offers stop, not restart.
    func startRecording() {
        guard state == .idle else { return }
        // macOS terminates the process on first capture input without this string, so check
        // it before touching AVFoundation rather than crashing into the wall.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String != nil else {
            errorMessage = MacVoiceFailure.microphoneDescriptionMissing.errorDescription
            return
        }
        errorMessage = nil
        state = .requestingPermission
        let current = UUID()
        generation = current
        operation = Task { [weak self] in
            let granted = await Self.requestMicrophoneAccess()
            guard let self, self.generation == current, !Task.isCancelled else { return }
            guard granted else {
                self.state = .idle
                self.errorMessage = MacVoiceFailure.microphonePermissionDenied.errorDescription
                return
            }
            do {
                try self.beginCapture()
            } catch {
                self.cancel()
                let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.errorMessage = MacVoiceFailure.recordingFailed(why).errorDescription
            }
        }
    }

    /// Assumes permission is already granted.
    private func beginCapture() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-voice-\(UUID().uuidString).m4a")
        fileURL = url
        // The phone's settings: 16 kHz mono AAC at 32 kbit/s. The bridge's ceiling is 10 MiB,
        // so a minute is a tenth of it.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = false
        guard recorder.record() else {
            throw MacVoiceFailure.recordingFailed("the input device did not start.")
        }
        self.recorder = recorder
        state = .recording
        startLimit()
    }

    /// At the limit, stop and transcribe rather than throw the words away: it behaves exactly
    /// as if the user had tapped stop one second earlier.
    private func startLimit() {
        limitTask?.cancel()
        limitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(MacVoiceWire.maxDuration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.state == .recording else { return }
            self.stopAndTranscribe()
        }
    }

    // MARK: Stop

    /// Stops capture, then sends the file to the host through the injected `transcribe`
    /// closure. The callback fires only for a nonempty real transcript; the composer decides
    /// where it goes and never sends on its own.
    func stopAndTranscribe() {
        guard state == .recording, let active = recorder, let url = fileURL else { return }
        limitTask?.cancel()
        limitTask = nil
        active.stop()
        self.recorder = nil
        state = .transcribing
        let current = generation
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = (try? Data(contentsOf: url)) ?? Data()
                self.discardRecording(url)
                guard !audio.isEmpty else { throw MacVoiceFailure.emptyRecording }
                let text = try await self.transcribe(audio, MacVoiceWire.recordingMimeType)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard self.generation == current, !Task.isCancelled else { return }
                guard !text.isEmpty else { throw MacVoiceFailure.emptyTranscript }
                self.state = .idle
                self.transcriptSink?(text)
            } catch {
                guard self.generation == current, !Task.isCancelled else { return }
                self.cancel()
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// Drop everything: capture, request in flight, and the temporary file. Safe to call in
    /// any state, and used when the composer goes away or the user switches session.
    func cancel() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        limitTask?.cancel()
        limitTask = nil
        recorder?.stop()
        recorder = nil
        if let url = fileURL { discardRecording(url) }
        fileURL = nil
        state = .idle
    }

    func clearError() { errorMessage = nil }

    private func discardRecording(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if fileURL == url { fileURL = nil }
    }

    // MARK: Permission

    /// `AVCaptureDevice` is the macOS gate for the input device. `.notDetermined` is the only
    /// state that shows a prompt; `.denied`/`.restricted` mean the answer is already no.
    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }
}

#endif
