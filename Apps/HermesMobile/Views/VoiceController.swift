import AVFoundation
import Foundation
import SwiftUI

/// Own one controller per visible voice control. Call cancel() when the owner disappears
/// or the app leaves the foreground. Requires NSMicrophoneUsageDescription in Info.plist.
/// The host's spoken answer failed, in words the caller can show.
struct VoiceSpeakFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class VoiceController: ObservableObject {
    enum State: Equatable { case idle, requestingPermission, recording, transcribing, synthesizing, playing }
    @Published private(set) var state: State = .idle
    @Published var errorMessage: String?
    /// Replaced when the pairing or the host changes; the controller owns no credentials.
    var transport: VoiceTransport
    /// The container the recorder writes, sent as the declared mime type.
    static let recordingMimeType = "audio/mp4"
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var fileURL: URL?
    private var operation: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    private var generation = UUID()
    private var interruptionObserver: NSObjectProtocol?
    private let maxDuration: TimeInterval = 60

    /// True while a tap would be ignored anyway; the controls use it to disable themselves.
    var isBusy: Bool { state != .idle && state != .recording }

    init(transport: VoiceTransport = .unavailable) {
        self.transport = transport
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state != .idle else { return }
                self.cancel()
                self.errorMessage = "Audio was interrupted. Please try again."
            }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        operation?.cancel()
        limitTask?.cancel()
        recorder?.stop()
        player?.stop()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    func startRecording() {
        guard state == .idle else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String != nil else {
            errorMessage = "Microphone usage description is missing from the app configuration."
            return
        }
        errorMessage = nil
        state = .requestingPermission
        let current = UUID()
        generation = current
        operation = Task { [weak self] in
            let allowed = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard let self, self.generation == current, !Task.isCancelled else { return }
            guard allowed else {
                self.state = .idle
                self.errorMessage = "Microphone access is denied. Enable it in Settings to record."
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
                self.fileURL = url
                let recorder = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
                ])
                guard recorder.record(forDuration: self.maxDuration) else { throw VoiceControllerError.recordingFailed }
                self.recorder = recorder
                self.state = .recording
                self.limitTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard !Task.isCancelled, let self, self.generation == current, self.state == .recording else { return }
                    // The owner can explicitly stop and transcribe before the limit.
                    self.cancel()
                    self.errorMessage = "Recording reached the 60-second limit. Please try a shorter message."
                }
            } catch {
                self.cancel()
                self.errorMessage = "Could not start recording: \(error.localizedDescription)"
            }
        }
    }

    /// Stops capture, then sends the recording to the injected service. The callback is
    /// called only for a nonempty real transcript; the caller decides whether to send it.
    func stopAndTranscribe(onTranscript: @escaping (String) -> Void) {
        guard state == .recording, let recorder, let url = fileURL else { return }
        limitTask?.cancel()
        limitTask = nil
        recorder.stop()
        self.recorder = nil
        state = .transcribing
        let current = generation
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try Data(contentsOf: url)
                self.removeRecording()
                guard !audio.isEmpty else { throw VoiceTransportError.emptyAudio }
                let text = try await self.transport.transcribe(audio, VoiceController.recordingMimeType)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard self.generation == current, !Task.isCancelled else { return }
                guard !text.isEmpty else { throw VoiceTransportError.emptyTranscript }
                self.state = .idle
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                onTranscript(text)
            } catch {
                guard self.generation == current, !Task.isCancelled else { return }
                self.cancel()
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "Voice transcription failed."
            }
        }
    }

    /// Speak and wait, so a caller with an error surface (a room's banner) can show the failure.
    /// `speak` itself is fire-and-forget: the conversation's auto-speak has nowhere to report.
    func speakAndWait(_ text: String) async throws {
        speak(text)
        // A busy controller ignores the request; that is not a failure to report.
        guard state == .synthesizing || state == .playing else { return }
        while state == .synthesizing || state == .playing {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        if let message = errorMessage {
            errorMessage = nil
            throw VoiceSpeakFailure(message: message)
        }
    }

    /// Synthesizes only the supplied reply; errors are visible, never silent fallback.
    func speak(_ text: String) {
        guard state == .idle, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        errorMessage = nil
        state = .synthesizing
        let current = UUID()
        generation = current
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.transport.synthesize(text)
                guard self.generation == current, !Task.isCancelled else { return }
                guard !audio.isEmpty else { throw VoiceTransportError.emptyAudio }
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                let player = try AVAudioPlayer(data: audio)
                guard player.play() else { throw VoiceControllerError.playbackFailed }
                self.player = player
                self.state = .playing
                while player.isPlaying {
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                guard self.generation == current, !Task.isCancelled else { return }
                self.player = nil
                self.state = .idle
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                guard self.generation == current, !Task.isCancelled else { return }
                self.cancel()
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "Voice playback failed."
            }
        }
    }

    /// Stops speech — synthesis in flight or audio already playing — without touching a
    /// recording. The toggle calls this when the user turns replies off.
    func stopSpeaking() {
        guard state == .synthesizing || state == .playing else { return }
        cancel()
    }

    func cancel() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        limitTask?.cancel()
        limitTask = nil
        recorder?.stop()
        recorder = nil
        player?.stop()
        player = nil
        removeRecording()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
    }

    private func removeRecording() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }
}

private enum VoiceControllerError: LocalizedError {
    case recordingFailed, playbackFailed
    var errorDescription: String? {
        switch self {
        case .recordingFailed: return "The microphone could not start recording."
        case .playbackFailed: return "The audio reply could not be played."
        }
    }
}
