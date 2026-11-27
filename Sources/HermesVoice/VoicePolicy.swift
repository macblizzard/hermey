import Foundation

/// The text decisions a hands-free conversation needs, kept pure so they can be exercised with no
/// microphone, no speaker and no host.
///
/// Every rule here is lifted from Hermes Agent's own chained voice mode, because that code has
/// already paid for the lessons on real conversations:
///
/// * `isHallucination` — `tools/voice_mode_transcript.py::is_whisper_hallucination`. Whisper
///   invents a short phrase when handed a silent or near-silent file ("thank you for watching"),
///   and without this a silent room becomes a turn.
/// * `isStopPhrase` — `voice_mode_transcript.py::is_voice_stop_phrase`. Deliberately strict: the
///   *whole* utterance must equal the phrase, so "stop doing that and try again" still reaches the
///   agent instead of ending the conversation.
/// * `isSelfEcho` — `voice_mode_transcript.py::is_tts_echo`. The Mac has no echo cancellation, so
///   the speaker's own words can come back through the microphone; a transcription that is mostly
///   the text we just spoke is the reply, not the user.
/// * `speechText` — the projection from `tools/tts_text_normalize.py::prepare_spoken_text`. The
///   reply on screen is markdown with code in it; what a person wants read out is the prose.
public enum VoicePolicy {

    // MARK: - Whisper on silence

    /// The lines Whisper is known to invent on silence, matched lowercased with trailing
    /// punctuation stripped. The non-English entries are as real as the English ones: a host set to
    /// another language hallucinates in that language, and `amara.org` subtitling credits are the
    /// most common of all.
    public static let whisperHallucinations: Set<String> = [
        "thank you", "thanks for watching", "subscribe to my channel", "like and subscribe",
        "please subscribe", "thank you for watching", "bye", "you", "the end",
        "продолжение следует", "sous-titres",
        "sous-titres réalisés par la communauté d'amara.org",
        "sottotitoli creati dalla comunità amara.org", "untertitel von stephanie geiges",
        "amara.org", "www.mooji.org", "ご視聴ありがとうございました",
    ]

    /// Words that make up a *repetition* hallucination — "Thank you. Thank you. Thank you." — which
    /// the exact-match set above cannot catch because the string never equals one phrase.
    private static let repetitionWords: Set<String> = [
        "thank", "thanks", "you", "bye", "ok", "okay", "the", "end",
    ]

    /// True when a transcript is one of Whisper's inventions rather than something a person said.
    public static func isHallucination(_ transcript: String) -> Bool {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return true }
        let bare = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        if whisperHallucinations.contains(bare) { return true }
        // A repetition needs at least two words: a single permitted word is already covered above.
        let words = cleaned
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard words.count >= 2 else { return false }
        return words.allSatisfy { repetitionWords.contains($0) }
    }

    // MARK: - Ending the loop by voice

    /// The default the host ships (`DEFAULT_VOICE_STOP_PHRASES`): one word, so it is hard to say by
    /// accident and easy to remember.
    public static let defaultStopPhrases: [String] = ["stop"]

    /// True when the utterance is *exactly* a stop phrase. Punctuation and case are forgiven; extra
    /// words are not, which is the point — an instruction that happens to contain "stop" must reach
    /// the agent.
    public static func isStopPhrase(_ transcript: String, phrases: [String] = defaultStopPhrases) -> Bool {
        let cleaned = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;: \t\n\"'"))
        guard !cleaned.isEmpty else { return false }
        return phrases.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.contains(cleaned)
    }

    /// The one line every surface shows when the loop opens, so the exit is discoverable.
    public static func stopHint(phrases: [String] = defaultStopPhrases) -> String {
        guard let first = phrases.first, !first.isEmpty else { return "" }
        return "Say “\(first)” to end"
    }

    // MARK: - Speaker bleed

    /// Character similarity above which a transcript is treated as our own words coming back.
    public static let echoSimilarityThreshold = 0.6
    /// Below this many characters the sliding-window fallback is skipped: a one-word interjection
    /// trivially matches a short window of a long reply.
    public static let minimumEchoFragmentLength = 10

    /// True when `transcript` looks like a capture of `spoken` rather than a reply to it.
    ///
    /// Whole-string similarity first; then, because a playback-phase capture is a *fragment* of a
    /// long reply, a transcript-sized window slides across the spoken text. A genuine interjection
    /// rarely matches either.
    public static func isSelfEcho(_ transcript: String,
                                  spoken: String,
                                  threshold: Double = echoSimilarityThreshold) -> Bool {
        let a = normalize(transcript), b = normalize(spoken)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if similarity(a, b) >= threshold { return true }
        if a.count < minimumEchoFragmentLength || a.count >= b.count { return false }
        let target = Array(a), haystack = Array(b)
        for start in 0...(haystack.count - target.count) {
            if similarity(String(haystack[start..<(start + target.count)]), a) >= threshold {
                return true
            }
        }
        return false
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 1.0 for identical strings, falling to 0.0. Levenshtein distance over the longer length — the
    /// same shape as `difflib.SequenceMatcher.ratio` for strings of similar length, cheap enough to
    /// run on a sentence in a UI callback.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        let distance = Double(previous[b.count])
        return 1 - distance / Double(max(a.count, b.count))
    }

    // MARK: - What is worth saying out loud

    /// The ceiling for one spoken reply. The bridge's own limit is 4 000 characters per request;
    /// this is a *listening* limit — nobody wants a file path spelled out.
    public static let maximumSpokenCharacters = 1_200

    /// Markdown → prose. Code, links and decoration are dropped rather than announced, which is
    /// what `prepare_spoken_text` does on the host for the same reason.
    public static func speechText(from reply: String) -> String {
        var text = reply
        // Fenced code: a spoken `if err != nil {` helps nobody. Drop the block, keep the prose.
        text = replace(text, pattern: "```[\\s\\S]*?```", with: " ")
        // Links keep their label; a bare URL is not something to read out.
        text = replace(text, pattern: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1")
        text = replace(text, pattern: "https?://\\S+", with: " ")
        // Table pipes and rules read as noise.
        text = replace(text, pattern: "^\\s*\\|?[-: ]{3,}\\|?[-: |]*$", with: " ", options: [.anchorsMatchLines])
        text = text.replacingOccurrences(of: "|", with: " ")
        // Heading and list markers, then the emphasis characters themselves.
        text = replace(text, pattern: "^\\s*#{1,6}\\s*", with: "", options: [.anchorsMatchLines])
        text = replace(text, pattern: "^\\s*[-*+•]\\s+", with: "", options: [.anchorsMatchLines])
        text = replace(text, pattern: "^\\s*\\d+[.)]\\s+", with: "", options: [.anchorsMatchLines])
        for marker in ["**", "__", "`", "*", "_", ">"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        text = text.replacingOccurrences(of: "\n", with: ". ")
        text = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // A double stop from the newline substitution ("done.. ") reads as a pause, not a period.
        text = replace(text, pattern: "\\.{2,}", with: ".")
        text = replace(text, pattern: "\\s+([.,!?;:])", with: "$1")
        if text.count > maximumSpokenCharacters {
            // Cut at a sentence if one is close, so the last thing heard is not half a word.
            let head = String(text.prefix(maximumSpokenCharacters))
            if let cut = head.lastIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }),
               head.distance(from: head.startIndex, to: cut) > maximumSpokenCharacters / 2 {
                text = String(head[...cut])
            } else {
                text = head
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ text: String,
                                pattern: String,
                                with template: String,
                                options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

/// Cuts a reply into speakable pieces so the first sentence can be spoken while the rest is still
/// being synthesized — the app-side equivalent of `tools/tts_streaming.py::SentenceChunker`.
///
/// The seam matters for a conversation: waiting for a five-sentence answer to be synthesized in one
/// request adds a second of silence before the first word, which reads as a broken connection.
public struct VoiceSentenceChunker {
    /// Fragments shorter than this are merged into the next sentence, exactly as the host's chunker
    /// does: "Yes." alone is a whole utterance in English but not worth its own TTS request... and
    /// more importantly, a 3-word sentence followed by a long one is better spoken together.
    public let minimumLength: Int
    private var buffer = ""

    public init(minimumLength: Int = 20) {
        self.minimumLength = max(1, minimumLength)
    }

    /// Absorb text; return every sentence now ready to speak.
    public mutating func feed(_ text: String) -> [String] {
        buffer += text
        var out: [String] = []
        var search = buffer.startIndex
        // Boundary: after . ! or ? followed by whitespace, or a blank line.
        while let boundary = nextBoundary(after: search) {
            let head = String(buffer[buffer.startIndex..<boundary])
            if head.trimmingCharacters(in: .whitespacesAndNewlines).count < minimumLength {
                // Too short to stand alone — "Yes." followed by a long sentence is one thing to
                // say, not two. Skip past this boundary and let the next one carry both, which is
                // what the host's chunker does rather than spending a request on three words.
                search = boundary
                continue
            }
            out.append(head)
            buffer = String(buffer[boundary...])
            search = buffer.startIndex
        }
        return out.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Drain the tail at the end of the reply.
    public mutating func flush() -> [String] {
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return tail.isEmpty ? [] : [tail]
    }

    /// The index just past a sentence boundary (the whitespace included), or `nil` when the buffer
    /// does not hold a complete sentence yet. A sentence that ends exactly at the end of the buffer
    /// is *not* complete: the next character could still be part of it. `flush()` drains that tail.
    private func nextBoundary(after start: String.Index) -> String.Index? {
        var cursor = start
        while cursor < buffer.endIndex {
            let character = buffer[cursor]
            if character == "." || character == "!" || character == "?" {
                let next = buffer.index(after: cursor)
                if next < buffer.endIndex, buffer[next].isWhitespace {
                    return buffer.index(after: next)
                }
            }
            cursor = buffer.index(after: cursor)
        }
        return nil
    }
}
