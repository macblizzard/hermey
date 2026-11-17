import Foundation
import SwiftUI

/// The Mac half of local computer use: one outbound, authenticated socket to the bridge.
///
/// Nothing listens on this Mac — no SSH, no Remote Login, no inbound port. The socket is dialed from
/// here with a per-connection ticket and re-dialed with exponential backoff, so a laptop that sleeps,
/// changes networks or is restarted comes back on its own. The toggle is off by default and revoking
/// a computer on the host closes its socket and refuses the next one.
@MainActor
final class LocalComputerService: ObservableObject {
    enum Status: String {
        case off
        case connecting
        case connected
        case reconnecting
        case refused
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var lastError: String?
    @Published private(set) var commandsRun = 0
    @Published private(set) var lastCommand: String?

    private let defaults = UserDefaults.standard
    private let enabledKey = "hermey.localComputer.enabled"
    private var enabled = false
    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    /// The machine name shown on the host's Computers list.
    private let machineName = Host.current().localizedName ?? "Mac"

    init() {
        enabled = defaults.bool(forKey: enabledKey)
        if enabled { status = .connecting }
    }

    var isEnabled: Bool { enabled }

    func setEnabled(_ value: Bool, address: PairingAddress?) {
        enabled = value
        defaults.set(value, forKey: enabledKey)
        if value {
            guard let address else {
                status = .refused
                lastError = "Pair this Mac with a host before enabling local computer use."
                return
            }
            lastError = nil
            status = .connecting
            loop?.cancel()
            loop = Task { await connectionLoop(address: address) }
        } else {
            loop?.cancel()
            loop = nil
            let closing = socket
            socket = nil
            closing?.cancel(with: .goingAway, reason: nil)
            status = .off
        }
    }

    /// Revoke this Mac on the host, not just locally. The bridge closes the live socket and refuses
    /// the next one until the toggle is turned on again.
    func revoke(address: PairingAddress?) async {
        setEnabled(false, address: nil)
        guard let address, !address.isTicketOnly,
              let ticket = try? await address.mintedTicket(),
              let origin = try? address.apiOrigin() else { return }
        var request = URLRequest(url: origin.appendingPathComponent("v1/local-computers/\(address.deviceID)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(ticket)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Called when the pairing changes: a live socket belongs to the old host's ticket.
    func pairingChanged(address: PairingAddress?) {
        guard enabled else { return }
        setEnabled(true, address: address)
    }

    // MARK: - Connection

    private func connectionLoop(address: PairingAddress) async {
        var backoff: UInt64 = 1_000_000_000
        while !Task.isCancelled, enabled {
            do {
                try await connectOnce(address: address)
                backoff = 1_000_000_000
            } catch {
                if Task.isCancelled { break }
                let code = (error as? WebSocketCloseCode)?.rawValue
                status = code == 4403 ? .refused : .reconnecting
                lastError = code == 4403
                    ? "Access was revoked on the host. Turn this Mac off and on again to re-request it."
                    : error.localizedDescription
            }
            guard enabled, !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: backoff)
            backoff = min(backoff * 2, 30_000_000_000)
        }
    }

    private func connectOnce(address: PairingAddress) async throws {
        let ticket = try await address.mintedTicket()
        let url = try address.localComputerSocketURL(ticket: ticket)
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        socket = task
        try await task.send(.string(#"{"type":"hello","name":"\#(machineName)"}"#))
        status = .connected
        lastError = nil

        // Two child tasks: receive frames and send a heartbeat. Whichever ends ends the connection;
        // the group cancellation closes the other. No polling and no per-frame layout work.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard case .string(let text) = message,
                          let data = text.data(using: .utf8),
                          let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let kind = frame["type"] as? String else { continue }
                    if kind == "pong" { continue }
                    if kind == "execute" {
                        await self.handleExecute(frame, on: task)
                    }
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                    try await task.send(.string(#"{"type":"ping"}"#))
                }
            }
            try await group.next()
            group.cancelAll()
        }
        task.cancel(with: .goingAway, reason: nil)
        if socket === task { socket = nil }
        if status == .connected { status = .reconnecting }
    }

    // MARK: - Commands

    private func handleExecute(_ frame: [String: Any], on task: URLSessionWebSocketTask) async {
        guard let id = frame["id"] as? String,
              let argv = frame["argv"] as? [String], !argv.isEmpty else { return }
        let cwd = frame["cwd"] as? String
        let timeout = frame["timeout_ms"] as? Int ?? 60_000
        let callID = id
        let result = await Task.detached(priority: .userInitiated) {
            LocalProcess.run(argv: argv, cwd: cwd, timeoutMS: timeout)
        }.value
        guard !Task.isCancelled else { return }
        commandsRun += 1
        lastCommand = argv.joined(separator: " ")
        let reply: [String: Any] = [
            "id": callID,
            "type": "result",
            "exit_code": result.exitCode,
            "stdout": result.stdout.base64EncodedString(),
            "stderr": result.stderr.base64EncodedString(),
            "truncated": result.truncated,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: reply),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await task.send(.string(text))
    }
}

/// One command, with a hard output cap and a deadline. No shell: argv goes straight to `Process`,
/// so a bot cannot smuggle a pipeline through a quoting mistake.
private struct LocalProcessResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let truncated: Bool
}

private enum LocalProcess {
    static let maxOutput = 1_000_000

    static func run(argv: [String], cwd: String?, timeoutMS: Int) -> LocalProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        var truncated = false

        // `inout` cannot escape into a closure; install the handlers directly instead.
        out.fileHandleForReading.readabilityHandler = { source in
            let piece = source.availableData
            guard !piece.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            if outData.count + piece.count <= maxOutput { outData.append(piece) } else { truncated = true }
        }
        err.fileHandleForReading.readabilityHandler = { source in
            let piece = source.availableData
            guard !piece.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            if errData.count + piece.count <= maxOutput { errData.append(piece) } else { truncated = true }
        }
        do {
            try process.run()
        } catch {
            return LocalProcessResult(exitCode: 127, stdout: Data(),
                                      stderr: Data(error.localizedDescription.utf8), truncated: false)
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMS) / 1000)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { process.kill() }
            lock.lock(); truncated = true; lock.unlock()
        }
        while process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        return LocalProcessResult(exitCode: process.terminationStatus,
                                  stdout: outData, stderr: errData, truncated: truncated)
    }
}
