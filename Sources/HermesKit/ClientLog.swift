import Foundation
#if canImport(os)
import os
#endif

/// How loud one line is. Three levels, because a user reading this wants to spot the failure, not
/// classify it.
public enum ClientLogLevel: String, Codable, Sendable, CaseIterable {
    case info, warning, error

    /// The one character the line carries in place of a word.
    public var marker: String {
        switch self {
        case .info: return "·"
        case .warning: return "!"
        case .error: return "E"
        }
    }
}

/// One recorded fact: when, how loud, from which part of the app, and what happened.
public struct ClientLogEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let at: Date
    public let level: ClientLogLevel
    public let category: String
    public let message: String

    public init(id: UUID = UUID(), at: Date = Date(),
                level: ClientLogLevel = .info,
                category: String = "app",
                message: String) {
        self.id = id
        self.at = at
        self.level = level
        self.category = category
        self.message = message
    }

    /// `12:04:11  E  bridge  session.resume failed: timeout`
    ///
    /// Built from calendar components rather than a shared `DateFormatter`: a formatter is not
    /// `Sendable` and this line is rendered from whatever thread asks for it.
    public var line: String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: at)
        let clock = String(format: "%02d:%02d:%02d",
                           parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return "\(clock)  \(level.marker)  \(category)  \(message)"
    }
}

/// What the app did, in the order it did it.
///
/// A failure on the phone reaches the user as "something went wrong" — the reason lives in a code
/// path they never see. Settings → View log is where that reason is written down: a bounded,
/// timestamped ring of the decisions and failures worth explaining later, kept on disk so a
/// relaunch (or a crash) does not erase the cause of the problem they are reporting.
///
/// Three rules, each of which keeps the log useful instead of noisy:
///
/// * **Bounded.** `capacity` entries, oldest dropped first, and the file is rewritten from the
///   buffer rather than appended to — it can never grow without limit on a phone with no space.
/// * **Cheap.** Recording is a queue hop and an array append; the disk write is debounced, so a
///   path that logs on every event cannot turn logging into I/O.
/// * **Readable by a person.** One line per entry, with the clock time first: the user can compare
///   it against the moment they saw the error.
public final class ClientLog: @unchecked Sendable {
    public static let shared = ClientLog()

    /// Where the app writes the log. `Application Support/Hermey/logs/client.log` — inside the
    /// app's own container on iOS, and `~/Library/Application Support/…` on the Mac.
    public static func defaultDirectory() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Hermey", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    /// The newest lines kept. 400 is a few screens of scrolling and well under a megabyte.
    public let capacity: Int

    private let queue = DispatchQueue(label: "dev.hermey.client-log", qos: .utility)
    private let fileURL: URL?
    private var buffer: [ClientLogEntry] = []
    private var flushScheduled = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(capacity: Int = 400, directory: URL? = ClientLog.defaultDirectory()) {
        self.capacity = max(50, capacity)
        let folder = directory
        self.fileURL = folder?.appendingPathComponent("client.log")
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // The tail of the previous run is the context for whatever is about to happen.
        self.buffer = Array(ClientLog.load(from: fileURL).suffix(max(50, capacity)))
    }

    /// Record one fact. Safe from any thread, any actor.
    public func record(_ message: String,
                       level: ClientLogLevel = .info,
                       category: String = "app") {
        let entry = ClientLogEntry(level: level, category: category, message: message)
        queue.async {
            self.buffer.append(entry)
            if self.buffer.count > self.capacity {
                self.buffer.removeFirst(self.buffer.count - self.capacity)
            }
            self.scheduleFlushLocked()
        }
        #if canImport(os)
        // The same line in the system log, so `log stream --predicate 'subsystem == "dev.hermey.app"'`
        // explains a running app without the user opening Settings.
        os.Logger(subsystem: "dev.hermey.app", category: category)
            .log("\(message, privacy: .public)")
        #endif
    }

    /// The entries, oldest first.
    public func snapshot() -> [ClientLogEntry] {
        queue.sync { buffer }
    }

    /// The whole log as text: what Copy and Share hand over.
    public func text() -> String {
        let lines = snapshot().map(\.line)
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The file this log is written to, for a user who wants to attach it by hand.
    public var fileLocation: String? { fileURL?.path }

    public var isEmpty: Bool { queue.sync { buffer.isEmpty } }

    /// Forget everything, on disk included.
    public func clear() {
        queue.sync {
            buffer.removeAll()
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        }
    }

    /// Write the buffer out now, debounce or not.
    public func flushNow() {
        queue.sync { writeLocked() }
    }

    // MARK: Storage

    private func scheduleFlushLocked() {
        guard !flushScheduled, fileURL != nil else { return }
        flushScheduled = true
        // A second is long enough that a burst becomes one write, and short enough that killing the
        // app right after the failure still leaves the failure on disk.
        queue.asyncAfter(deadline: .now() + 1.0) {
            self.flushScheduled = false
            self.writeLocked()
        }
    }

    private func writeLocked() {
        guard let fileURL else { return }
        let lines = buffer.compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let text = lines.joined(separator: "\n")
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func load(from url: URL?) -> [ClientLogEntry] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(ClientLogEntry.self, from: data)
        }
    }
}

public extension ClientLog {
    /// One-line convenience for call sites that do not want to name the shared instance.
    static func note(_ message: String,
                     level: ClientLogLevel = .info,
                     category: String = "app") {
        shared.record(message, level: level, category: category)
    }
}
