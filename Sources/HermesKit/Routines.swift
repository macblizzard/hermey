import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - A bot's routines

/// One of a bot's schedules, as the bridge reports it (`GET /v1/bots/{profile}/routines`).
///
/// Deliberately *not* the host's cron job: the prompt is absent, because a routine's prompt is the
/// bot's own instructions — long, often private — and a list of when this bot runs never needs it.
/// What is here is what a row draws, and the switch that pauses it.
///
/// A routine has three states a row has to tell apart, and the wire says so with two flags rather
/// than one: `paused` is "switched off on purpose", `completed` is "a one-shot that already ran".
/// Drawing the second as the first would offer a switch that re-arms something the owner finished
/// with.
public struct BotRoutine: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// The host's own words for the schedule ("every day at 3am"), so the app never re-derives a
    /// cron expression into a sentence of its own and gets it subtly wrong.
    public let schedule: String
    /// ISO-8601 stamps, straight off the wire. Kept as strings for decoding and turned into text by
    /// `whenText`, so the formatting is testable without a clock.
    public let nextRunAt: String?
    public let lastRunAt: String?
    /// The last run's verdict: `ok`, `error`, `running`, or absent if it never ran.
    public let lastStatus: String?
    public let lastError: String?
    public let paused: Bool
    public let completed: Bool

    public init(id: String, name: String, schedule: String,
                nextRunAt: String? = nil, lastRunAt: String? = nil,
                lastStatus: String? = nil, lastError: String? = nil,
                paused: Bool = false, completed: Bool = false) {
        self.id = id
        self.name = name
        self.schedule = schedule
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.lastError = lastError
        self.paused = paused
        self.completed = completed
    }

    /// What the row says under the name: when it next runs, or why it will not.
    public func timingText(now: Date = Date()) -> String {
        if paused { return "Paused" }
        if completed { return "Finished" }
        guard let next = Self.whenText(nextRunAt, now: now) else { return schedule }
        return "Next \(next)"
    }

    /// The last run, as one short line. A failure says so and says why — a row that only said
    /// "failed" sends the owner to the desktop dashboard to find out what a phone told him nothing
    /// about.
    public func lastRunText(now: Date = Date()) -> String? {
        guard let lastRun = Self.whenText(lastRunAt, now: now) else { return nil }
        let verdict = (lastStatus ?? "").lowercased()
        switch verdict {
        case "ok", "completed", "success", "succeeded":
            return "Ran \(lastRun)"
        case "error", "failed", "failure":
            if let lastError, !lastError.isEmpty {
                return "Failed \(lastRun) — \(lastError)"
            }
            return "Failed \(lastRun)"
        case "":
            return "Ran \(lastRun)"
        default:
            return "\(lastStatus ?? "") \(lastRun)"
        }
    }

    /// Whether a switch makes sense: a finished one-shot does not resume, it re-arms, and that is a
    /// different decision than the one this row is for.
    public var canToggle: Bool { !completed }

    /// "3 hours ago" / "in 2 days", from one of the host's ISO-8601 stamps.
    ///
    /// Computed here rather than through `RelativeDateTimeFormatter`: that class does not exist in
    /// swift-corelibs Foundation, so a formatter-based row would fail to build (and read
    /// differently) away from Apple's platforms — and a row with no reason to change per platform is
    /// a row that should not.
    static func whenText(_ stamp: String?, now: Date) -> String? {
        guard let date = date(from: stamp) else { return nil }
        return relativeText(from: date, now: now)
    }

    /// Parse one of the host's stamps. Both shapes occur: with and without fractional seconds, and
    /// the offset is sometimes `Z`. A row must not go blank because of a trailing decimal.
    static func date(from stamp: String?) -> Date? {
        guard let stamp, !stamp.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let precise = formatter.date(from: stamp) { return precise }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stamp)
    }

    /// "in 3 h" / "2 d ago" / "now": short enough to sit at the end of a row, and unambiguous in
    /// both directions.
    static func relativeText(from date: Date, now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        let seconds = abs(delta)
        if seconds < 60 { return "now" }
        let amount: String
        switch seconds {
        case ..<3600: amount = "\(Int(seconds / 60)) m"
        case ..<86_400: amount = "\(Int(seconds / 3600)) h"
        case ..<604_800: amount = "\(Int(seconds / 86_400)) d"
        default: amount = "\(Int(seconds / 604_800)) w"
        }
        return delta >= 0 ? "in \(amount)" : "\(amount) ago"
    }

    /// Read one wire row. Returns nil for a row with no id, which is the only field a list cannot
    /// work without.
    static func decode(_ object: [String: Any]) -> BotRoutine? {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        return BotRoutine(
            id: id,
            name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
            schedule: object["schedule"] as? String ?? "",
            nextRunAt: object["next_run_at"] as? String,
            lastRunAt: object["last_run_at"] as? String,
            lastStatus: object["last_status"] as? String,
            lastError: object["last_error"] as? String,
            paused: object["paused"] as? Bool ?? false,
            completed: object["completed"] as? Bool ?? false
        )
    }

    /// `{"routines": [...]}` → rows, in the order the bridge sent them (soonest first).
    public static func decodeList(_ data: Data) -> [BotRoutine] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["routines"] as? [[String: Any]]
        else { return [] }
        return rows.compactMap(decode)
    }
}
