import Foundation

/// What the loop is doing, in one word, at all times.
///
/// The states are explicit rather than derived from flags because the visible indicator, the audio
/// teardown and the guard tests all need one answer to "is the microphone open right now?":
///
/// * `off` — no microphone, no playback. The resting state and the one every exit returns to.
/// * `starting` — the permission prompt is up and the engine is being built. Nothing is captured
///   yet, and saying `listening` here would be a lie the user can hear (the prompt is on screen).
/// * `listening` — the microphone is open and the endpointing gate is armed.
/// * `thinking` — an utterance was uploaded and the host is running the turn. The microphone stays
///   open so the user can interrupt the generation.
/// * `speaking` — the reply is being synthesized and played. The microphone stays open for
///   barge-in, which is the whole difference between a conversation and a walkie-talkie.
/// * `failed` — the last request failed. Audio is already torn down; the message says what to do.
public enum VoiceLoopState: String, CaseIterable, Sendable, Equatable {
    case off
    case starting
    case listening
    case thinking
    case speaking
    case failed

    /// True whenever this object owns the microphone, so a second capture (the composer's
    /// hold-to-talk) can refuse to start and two listeners can never run at once.
    public var ownsMicrophone: Bool {
        switch self {
        case .starting, .listening, .thinking, .speaking: return true
        case .off, .failed: return false
        }
    }

    /// The word in the status strip. Short on purpose: it sits in a composer.
    public var title: String {
        switch self {
        case .off: return "Voice off"
        case .starting: return "Starting…"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .failed: return "Voice stopped"
        }
    }

    /// The SF Symbol the strip draws. `waveform` is the loop's own mark in the composer, so the
    /// indicator and the control read as the same thing.
    public var glyph: String {
        switch self {
        case .off: return "waveform"
        case .starting: return "waveform.badge.mic"
        case .listening: return "mic.fill"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}
