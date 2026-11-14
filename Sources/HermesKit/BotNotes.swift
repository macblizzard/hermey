import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A bot's own notes: the owner's plan for this bot, written by hand.
///
/// Different in kind from `BotMemory` — that is what the *agent* wrote for itself and what the host
/// carries into every turn; this is what the *owner* wrote about the bot, read by nobody but the
/// next person to open the sheet. It lives on the host (`<profile>/NOTES.md`), so it follows the bot
/// to every device and disappears with the bot when the bot is deleted.
public struct BotNotes: Hashable, Sendable {
    public let profile: String
    public let text: String
    public let chars: Int
    /// False for a bot nobody has written a note for yet — a normal state, not a fault.
    public let present: Bool
    /// When the file was last written, from the host's own clock.
    public let updatedAt: Date?
    /// Present when the host could not read the note (permissions, a symlink). "Could not read it"
    /// and "nothing written yet" must not look the same on screen.
    public let error: String?

    public init(profile: String, text: String = "", chars: Int = 0, present: Bool = false,
                updatedAt: Date? = nil, error: String? = nil) {
        self.profile = profile
        self.text = text
        self.chars = chars
        self.present = present
        self.updatedAt = updatedAt
        self.error = error
    }

    /// "1,240 characters" — the size of what will come back on the next device.
    public var sizeText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let count = formatter.string(from: NSNumber(value: chars)) ?? "\(chars)"
        return chars == 1 ? "1 character" : "\(count) characters"
    }

    static func decode(_ object: [String: Any]) -> BotNotes? {
        guard let payload = object["notes"] as? [String: Any] else { return nil }
        let text = payload["text"] as? String ?? ""
        return BotNotes(
            profile: object["profile"] as? String ?? payload["profile"] as? String ?? "",
            text: text,
            chars: payload["chars"] as? Int ?? text.count,
            present: payload["present"] as? Bool ?? !text.isEmpty,
            updatedAt: (payload["updated_at"] as? String).flatMap(Self.parse),
            error: payload["error"] as? String
        )
    }

    /// ISO-8601 with fractional seconds, then without: the host writes `datetime.isoformat()`, whose
    /// fractional part is optional.
    private static func parse(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
