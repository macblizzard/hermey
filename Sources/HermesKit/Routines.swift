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

    /// `{"routine": {...}}` → the row the create route answered with.
    public static func decodeOne(_ data: Data) -> BotRoutine? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let row = object["routine"] as? [String: Any]
        else { return nil }
        return decode(row)
    }

    /// `{"routines": [...]}` → rows, in the order the bridge sent them (soonest first).
    public static func decodeList(_ data: Data) -> [BotRoutine] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["routines"] as? [[String: Any]]
        else { return [] }
        return rows.compactMap(decode)
    }
}

// MARK: - Creating one

/// The schedule picker's modes: the same six the official app offers.
public enum RoutineScheduleMode: String, CaseIterable, Sendable, Identifiable {
    case daily, weekly, monthly, repeating, once, custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .repeating: return "Repeat"
        case .once: return "Once"
        case .custom: return "Custom"
        }
    }
}

/// When a routine runs, as a picker holds it — and the host's own schedule string it becomes.
///
/// The app never parses a schedule back out of this; it only produces one. The host accepts a cron
/// expression ("0 9 * * *"), an interval ("every 2h"), an absolute ISO timestamp for a one-shot, and
/// any other text with a schedule it understands for Custom, so each mode maps onto the shape it is
/// really expressing instead of everything being forced into cron.
public struct RoutineSchedule: Equatable, Sendable {
    public enum RepeatUnit: String, CaseIterable, Sendable, Identifiable {
        case minutes, hours
        public var id: String { rawValue }
        public var label: String { self == .minutes ? "Minutes" : "Hours" }
        var suffix: String { self == .minutes ? "m" : "h" }
    }

    public var mode: RoutineScheduleMode = .daily
    /// 24-hour clock, local to the phone: the host resolves the expression in the profile's timezone.
    public var hour: Int = 9
    public var minute: Int = 0
    /// `Calendar`'s numbering (1 = Sunday), converted for cron below. Monday by default.
    public var weekday: Int = 2
    public var dayOfMonth: Int = 1
    public var repeatCount: Int = 15
    public var repeatUnit: RepeatUnit = .minutes
    public var onceAt: Date = Date().addingTimeInterval(3600)
    public var custom: String = ""

    public init() {}

    /// The string the bridge and the host both understand.
    public var expression: String {
        switch mode {
        case .daily:
            return "\(minute) \(hour) * * *"
        case .weekly:
            // cron counts Sunday as 0 and Saturday as 6; Calendar counts Sunday as 1 and Saturday as
            // 7. The conversion is therefore a subtraction, not a wrap: `weekday % 7` sends Monday to
            // 2 (Wednesday) and Sunday to 1 (Monday).
            return "\(minute) \(hour) * * \(max(0, min(6, weekday - 1)))"
        case .monthly:
            return "\(minute) \(hour) \(dayOfMonth) * *"
        case .repeating:
            return "every \(repeatCount)\(repeatUnit.suffix)"
        case .once:
            return Self.isoStamp(onceAt)
        case .custom:
            return custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// What the form says under the picker, in words — the official app's "Daily at 09:00".
    public var summary: String {
        let clock = String(format: "%02d:%02d", hour, minute)
        switch mode {
        case .daily:
            return "Daily at \(clock)"
        case .weekly:
            return "Weekly on \(Self.weekdayName(weekday)) at \(clock)"
        case .monthly:
            return "Monthly on the \(Self.ordinal(dayOfMonth)) at \(clock)"
        case .repeating:
            let unit = repeatCount == 1 ? (repeatUnit == .minutes ? "minute" : "hour")
                                        : repeatUnit.label.lowercased()
            return "Every \(repeatCount) \(unit)"
        case .once:
            let day = Self.dayStamp(onceAt)
            return "Once on \(day) at \(Self.clockStamp(onceAt))"
        case .custom:
            let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Custom schedule" : trimmed
        }
    }

    /// A one-shot needs a time in the future; every other mode is valid as soon as it is built.
    public var isValid: Bool {
        if mode == .custom { return !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if mode == .once { return onceAt > Date() }
        if mode == .repeating { return repeatCount >= 1 }
        return true
    }

    public static func weekdayName(_ weekday: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let index = max(1, min(7, weekday)) - 1
        return names[index]
    }

    public static func ordinal(_ day: Int) -> String {
        let suffix: String
        switch (day % 100, day % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(day)\(suffix)"
    }

    /// `2026-11-18T09:00:00` in local time — what the host reads as an absolute one-shot.
    static func isoStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:00"
        return formatter.string(from: date)
    }

    static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    static func clockStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// The New Routine form's contents.
///
/// `problem` is the whole validation rule, in one place: the Create button reads it, the message under
/// the button is it, and the bridge enforces the same sentence, so a form and a replayed request
/// cannot disagree about whether a routine is complete.
public struct RoutineDraft: Equatable, Sendable {
    public var name: String = ""
    public var schedule: RoutineSchedule = RoutineSchedule()
    public var prompt: String = ""
    /// Skill names, one per entry. The form splits its comma-separated field into these.
    public var skills: [String] = []
    public var script: String = ""
    /// "local" keeps the run in the history; "bot-chat:<profile>" posts it into a bot's chat.
    public var deliver: String = "local"
    public var paused: Bool = false

    public init() {}

    /// Nil when the draft can be created; otherwise the sentence to show.
    public var problem: String? {
        let scheduleText = schedule.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if scheduleText.isEmpty { return "Pick when this routine should run." }
        if !schedule.isValid { return "A one-shot routine needs a time in the future." }

        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let scriptText = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSkill = skills.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if promptText.isEmpty && scriptText.isEmpty && !hasSkill {
            return "This routine needs a prompt, a skill, or a script."
        }
        return nil
    }

    public var isCreatable: Bool { problem == nil }

    /// The JSON body of `POST /v1/bots/{profile}/routines`.
    public func payload() -> [String: Any] {
        var body: [String: Any] = [
            "schedule": schedule.expression,
            "deliver": deliver,
            "paused": paused,
        ]
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { body["name"] = trimmedName }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty { body["prompt"] = trimmedPrompt }
        let trimmedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedScript.isEmpty { body["script"] = trimmedScript }
        let cleanedSkills = skills.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanedSkills.isEmpty { body["skills"] = cleanedSkills }
        return body
    }
}

