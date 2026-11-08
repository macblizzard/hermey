import AVFoundation
import Foundation

/// One speech channel for the whole window.
///
/// Read aloud used to live only inside a row's context menu, with a `static` synthesizer and no
/// state: nothing on screen said a message was being read, and a second "Read Aloud" talked over
/// the first. This type owns the single voice, so the row that is speaking can show *Stop* and
/// every other row can offer *Read aloud*.
///
/// Not `@MainActor`: `AVSpeechSynthesizerDelegate` callbacks arrive on the synthesiser's own
/// queue, and touching `@Published` off the main thread is what a wrapper class would be for.
/// Only the delegate hops back, and only to clear one string.
final class SpeechReader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechReader()

    /// The transcript row currently being read, if any.
    @Published private(set) var speakingEntryID: String?

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speak this message, or stop it if it is the one already speaking — one button, both jobs.
    func toggle(id: String, text: String) {
        if speakingEntryID == id {
            stop()
            return
        }
        stop()
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speakingEntryID = id
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        if speakingEntryID != nil { speakingEntryID = nil }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        clear()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        clear()
    }

    private func clear() {
        if Thread.isMainThread {
            if speakingEntryID != nil { speakingEntryID = nil }
        } else {
            DispatchQueue.main.async { [weak self] in
                if self?.speakingEntryID != nil { self?.speakingEntryID = nil }
            }
        }
    }
}
