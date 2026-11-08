import Foundation

/// How a message's time is written.
///
/// A chat is read in two moods: the recent past, where "14:32" is enough, and the older scroll
/// where a bare clock time leaves you guessing which day. So today's messages keep the clock alone
/// and everything older carries its date. Kept Foundation-only and pure, so the rule can be pinned
/// without a simulator — the alternative is `Text(date, style: .time)`, which cannot say the date
/// for an older row at all.
public enum MessageTime {

    /// `14:32` for today, `5 Nov, 14:32` before that — never a year, because a chat does not
    /// usually span one and the row is meant to be glanceable rather than a timestamp record.
    public static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let clock = formatter(calendar: calendar, withDate: false).string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return clock }

        let dated = formatter(calendar: calendar, withDate: true).string(from: date)
        // Yesterday is worth naming: it is the one date a person reads without doing arithmetic.
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(clock)"
        }
        return dated
    }

    private static let lock = NSLock()
    private static var cache: [String: DateFormatter] = [:]

    /// Date formatters are expensive to build and not safe to share across threads, so each
    /// combination gets one instance guarded by a lock.
    private static func formatter(calendar: Calendar, withDate: Bool) -> DateFormatter {
        let key = "\(withDate)-\(calendar.identifier)-\(calendar.timeZone.identifier)"
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[key] { return cached }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = withDate ? "d MMM, HH:mm" : "HH:mm"
        cache[key] = formatter
        return formatter
    }
}
