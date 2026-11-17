import Darwin
import Foundation
import HermesKit
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
    private var session: URLSession?
    private var heartbeat: Timer?
    private var lastPong = Date()

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
            drop(socket)
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
                ClientLog.shared.record("local computer reconnecting: \(error.localizedDescription)",
                                        level: .warning, category: "local-computer")
                let code = (error as? URLSessionWebSocketTask.CloseCode)?.rawValue
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
        // The default URLSession request timeout is 60 s. A socket that only waits for a command can
        // hit it while a two-minute Xcode build is running, which used to kill an in-flight call.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3_600
        config.timeoutIntervalForResource = 86_400
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        self.session = session
        let task = session.webSocketTask(with: url)
        task.resume()
        socket = task
        try await task.send(.string(#"{"type":"hello","name":"\#(machineName)"}"#))
        status = .connected
        lastError = nil
        lastPong = Date()
        ClientLog.shared.record("local computer socket connected", category: "local-computer")

        // One timer, one receive loop. An earlier task group let a heartbeat send error cancel the
        // receive loop (or vice versa) at ~45 s; the timer owns the ping and completion callbacks
        // keep every send off the async path that can throw through the group.
        let timer = Timer(timeInterval: 15, repeats: true) { _ in
            Task { @MainActor [weak self, weak task] in
                guard let self, let task, self.socket === task else { return }
                if Date().timeIntervalSince(self.lastPong) > 60 {
                    self.drop(task)
                    return
                }
                task.send(.string(#"{"type":"ping"}"#)) { error in
                    if error != nil {
                        Task { @MainActor in self.drop(task) }
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        do {
            try await receiveFrames(on: task)
        } catch {
            finish(task, timer: timer)
            throw error
        }
        finish(task, timer: timer)
    }

    private func receiveFrames(on task: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let message = try await task.receive()
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = frame["type"] as? String else { continue }
            if kind == "pong" {
                lastPong = Date()
                continue
            }
            if kind == "execute" {
                // Never await a command inside the receive loop: doing that stopped us reading the
                // bridge's pongs for the whole build, which made the link look dead and dropped it.
                Task { @MainActor [weak self] in
                    await self?.handleExecute(frame, on: task)
                }
            } else if kind == "observe" {
                Task { @MainActor [weak self] in
                    await self?.handleObserve(frame, on: task)
                }
            }
        }
    }

    /// End one connection without touching the outer reconnect loop. Cancelling the task makes the
    /// receive loop throw, which returns to `connectionLoop` and starts the backoff sequence.
    private func drop(_ task: URLSessionWebSocketTask?) {
        guard let task, socket === task else { return }
        ClientLog.shared.record("local computer socket dropped", level: .warning,
                                category: "local-computer")
        heartbeat?.invalidate()
        heartbeat = nil
        socket = nil
        task.cancel(with: .goingAway, reason: nil)
    }

    private func finish(_ task: URLSessionWebSocketTask, timer: Timer) {
        timer.invalidate()
        if heartbeat === timer { heartbeat = nil }
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
        ClientLog.shared.record("local command finished: \(argv.first ?? "") exit=\(result.exitCode)",
                                category: "local-computer")
        let reply: [String: Any] = [
            "id": callID,
            "type": "result",
            "exit_code": result.exitCode,
            "stdout": result.stdout.base64EncodedString(),
            "stderr": result.stderr.base64EncodedString(),
            "truncated": result.truncated,
        ]
        sendReply(reply, on: task)
    }

    private func handleObserve(_ frame: [String: Any], on task: URLSessionWebSocketTask) async {
        guard let id = frame["id"] as? String else { return }
        let result = await Task.detached(priority: .userInitiated) {
            Result<ComputerObservation, Error> { try ComputerObserver.shared.observe() }
        }.value
        switch result {
        case .success(let observation):
            guard let data = try? JSONEncoder().encode(observation),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                sendReply(["id": id, "type": "result", "error": "observation encoding failed"], on: task)
                return
            }
            sendReply(["id": id, "type": "result", "exit_code": 0,
                       "observation": object, "stderr": "", "truncated": false], on: task)
        case .failure(let error):
            sendReply(["id": id, "type": "result", "exit_code": 1,
                       "error": error.localizedDescription], on: task)
        }
    }

    private func sendReply(_ reply: [String: Any], on task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: reply),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if error != nil {
                Task { @MainActor in self?.drop(task) }
            }
        }
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
    // Xcode builds are chatty; four megabytes still clips a runaway log without starving them.
    static let maxOutput = 4_000_000

    static func run(argv: [String], cwd: String?, timeoutMS: Int) -> LocalProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        // A GUI app does not inherit a login shell's PATH. Homebrew, Swift and Xcode toolchains
        // would be invisible to a bot otherwise, so the common developer paths are prepended.
        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? ""
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
            + inheritedPath
        process.environment = environment

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
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
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
