import AppKit
import CoreGraphics
import Foundation

/// A single desktop action. Parsed from the bridge's JSON by hand because the wire format is a
/// dictionary and the action set is deliberately small and explicit.
struct ComputerAction {
    let kind: String
    let x: Double?
    let y: Double?
    let button: String?
    let text: String?
    let key: String?
    let modifiers: [String]
    let direction: String?
    let amount: Int?
    let application: String?
    let path: String?
    let milliseconds: Int?

    init(_ dict: [String: Any]) {
        kind = dict["kind"] as? String ?? ""
        x = dict["x"] as? Double ?? (dict["x"] as? Int).map(Double.init)
        y = dict["y"] as? Double ?? (dict["y"] as? Int).map(Double.init)
        button = dict["button"] as? String
        text = dict["text"] as? String
        key = dict["key"] as? String
        modifiers = dict["modifiers"] as? [String] ?? []
        direction = dict["direction"] as? String
        amount = dict["amount"] as? Int
        application = dict["application"] as? String
        path = dict["path"] as? String
        milliseconds = dict["milliseconds"] as? Int
    }
}

private enum ActError: LocalizedError {
    case permission
    case locked
    case tooMany
    case coordinates(String)
    case observeFirst
    case unknown(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permission: return "Accessibility access is off. Enable it in Settings → Computer."
        case .locked: return "The display is locked; refusing to drive the desktop."
        case .tooMany: return "A batch may contain at most 24 actions."
        case .coordinates(let why): return "Invalid coordinates: \(why). Take a fresh observation first."
        case .observeFirst: return "Take a `computer observe` first; coordinate actions need a fresh screen."
        case .unknown(let kind): return "Unknown action kind: \(kind)."
        case .failed(let why): return "Action failed: \(why)."
        }
    }
}

/// One bot at a time drives the desktop. A FIFO waiter keeps two simultaneous batches from being
/// interleaved; every acquisition is paired with a release even on cancellation or disconnect.
actor ComputerGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            busy = false
        }
    }
}

/// Executes CGEvent batches and returns a fresh observation so the caller can see the result.
@MainActor
final class ComputerActions {
    static let shared = ComputerActions()
    static let gate = ComputerGate()
    private let eventTag: Int64 = 0x4845524D  // HERM — lets a future event tap ignore our own events.

    /// The last observation timestamp is set by the observe command, not by a timer. Coordinate
    /// actions are refused without one, which prevents blind clicks on a stale layout.
    private(set) var lastObservationAt = Date.distantPast
    func noteObservation() { lastObservationAt = Date() }

    func perform(_ raw: [[String: Any]], bot: String) async throws -> ComputerObservation {
        guard !raw.isEmpty else { throw ActError.unknown("empty batch") }
        guard raw.count <= 24 else { throw ActError.tooMany }
        try Self.requireUnlocked()
        await Self.gate.acquire()
        defer { Task { await Self.gate.release() } }
        let actions = raw.map(ComputerAction.init)
        for action in actions { try validate(action) }
        for action in actions {
            try await apply(action)
        }
        return try ComputerObserver.shared.observe()
    }

    private static func requireUnlocked() throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool, locked {
            throw ActError.locked
        }
    }

    private func validate(_ action: ComputerAction) throws {
        if ["click", "move", "scroll"].contains(action.kind) {
            if Date().timeIntervalSince(lastObservationAt) > 30 { throw ActError.observeFirst }
            guard let x = action.x, let y = action.y else {
                throw ActError.coordinates("missing x/y")
            }
            let bounds = CGDisplayBounds(CGMainDisplayID())
            guard x >= 0, y >= 0, x <= Double(bounds.width), y <= Double(bounds.height) else {
                throw ActError.coordinates("(\(x), \(y)) is outside the display")
            }
        }
    }

    @MainActor
    private func apply(_ action: ComputerAction) async throws {
        switch action.kind {
        case "click":
            let type: CGEventType = action.button == "right" ? .rightMouseDown : .leftMouseDown
            let up: CGEventType = action.button == "right" ? .rightMouseUp : .leftMouseUp
            let button: CGMouseButton = action.button == "right" ? .right : .left
            post(CGEvent(mouseEventSource: nil, mouseType: type,
                         mouseCursorPosition: CGPoint(x: action.x ?? 0, y: action.y ?? 0),
                         mouseButton: button))
            post(CGEvent(mouseEventSource: nil, mouseType: up,
                         mouseCursorPosition: CGPoint(x: action.x ?? 0, y: action.y ?? 0),
                         mouseButton: button))
        case "move":
            post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                         mouseCursorPosition: CGPoint(x: action.x ?? 0, y: action.y ?? 0),
                         mouseButton: .left))
        case "down", "up":
            let isDown = action.kind == "down"
            let type: CGEventType
            switch action.button {
            case "right": type = isDown ? .rightMouseDown : .rightMouseUp
            default: type = isDown ? .leftMouseDown : .leftMouseUp
            }
            post(CGEvent(mouseEventSource: nil, mouseType: type,
                         mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero,
                         mouseButton: action.button == "right" ? .right : .left))
        case "type":
            for character in action.text ?? "" {
                if character == "\n" {
                    post(keyEvent(36, down: true, modifiers: []))
                    post(keyEvent(36, down: false, modifiers: []))
                    continue
                }
                guard let pair = Self.virtualKey(for: character) else { continue }
                var flags = pair.shift ? ["shift"] : []
                post(keyEvent(pair.code, down: true, modifiers: flags))
                post(keyEvent(pair.code, down: false, modifiers: flags))
            }
        case "key":
            guard let code = Self.virtualKey(action.key ?? "") else {
                throw ActError.unknown(action.key ?? "")
            }
            post(keyEvent(code, down: true, modifiers: action.modifiers))
            post(keyEvent(code, down: false, modifiers: action.modifiers))
        case "scroll":
            let delta = action.amount ?? 3
            let dx = action.direction == "left" ? -delta : (action.direction == "right" ? delta : 0)
            let dy = action.direction == "up" ? -delta : (action.direction == "down" ? delta : delta)
            post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                         wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0))
        case "wait":
            let ms = min(max(action.milliseconds ?? 100, 0), 5_000)
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        case "focus":
            try focus(action.application ?? "", uri: action.path)
        case "open_path":
            guard let path = action.path, let url = URL(string: path) else {
                throw ActError.failed("missing path")
            }
            guard NSWorkspace.shared.open(url) else { throw ActError.failed("could not open \(path)") }
        default:
            throw ActError.unknown(action.kind)
        }
    }

    private func focus(_ name: String, uri: String?) throws {
        let workspace = NSWorkspace.shared
        var app: NSRunningApplication?
        if let uri, let url = URL(string: uri), let found = workspace.runningApplications.first(where: {
            $0.bundleURL == url
        }) {
            app = found
        } else {
            app = workspace.runningApplications.first {
                $0.localizedName == name || $0.bundleIdentifier == name
            }
        }
        if app == nil {
            let found = name.contains("/") ? URL(fileURLWithPath: name) : URL(fileURLWithPath: "/Applications/\(name).app")
            guard workspace.launchApplication(at: found, options: [], configuration: [:]) else {
                throw ActError.failed("could not launch \(name)")
            }
            app = workspace.runningApplications.first { $0.localizedName == name || $0.bundleIdentifier == name }
        }
        guard let app else { throw ActError.failed("could not find \(name)") }
        guard app.activate(options: [.activateIgnoringOtherApps]) else {
            throw ActError.failed("could not focus \(name)")
        }
    }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        tag(event)
        event.post(tap: .cghidEventTap)
    }

    private func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: eventTag)
    }

    private func keyEvent(_ code: CGKeyCode, down: Bool, modifiers: [String]) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return nil }
        var flags: CGEventFlags = []
        if modifiers.contains("cmd") { flags.insert(.maskCommand) }
        if modifiers.contains("shift") { flags.insert(.maskShift) }
        if modifiers.contains("option") || modifiers.contains("alt") { flags.insert(.maskAlternate) }
        if modifiers.contains("ctrl") { flags.insert(.maskControl) }
        event.flags = flags
        return event
    }

    private static func virtualKey(for character: Character) -> (code: CGKeyCode, shift: Bool)? {
        let c = String(character)
        let map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "7": 26, "8": 28,
            "9": 25, "0": 29, "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42,
            ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, " ": 49, "\n": 36,
        ]
        if let code = map[c.lowercased()] { return (code, c != c.lowercased()) }
        let shifted: [String: CGKeyCode] = [
            "!": 18, "@": 19, "#": 20, "$": 21, "%": 23, "^": 22, "&": 26, "*": 28,
            "(": 25, ")": 29, "_": 27, "+": 24, "{": 33, "}": 30, "|": 42,
            ":": 41, "\"": 39, "<": 43, ">": 47, "?": 44, "~": 10,
        ]
        if let code = shifted[c] { return (code, true) }
        return nil
    }

    private static func virtualKey(_ name: String) -> CGKeyCode? {
        switch name.lowercased() {
        case "return", "enter": return 36
        case "tab": return 48
        case "space": return 49
        case "delete", "backspace": return 51
        case "escape", "esc": return 53
        case "left": return 123
        case "right": return 124
        case "down": return 125
        case "up": return 126
        default: return nil
        }
    }
}
