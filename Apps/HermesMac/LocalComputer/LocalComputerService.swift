import Combine
import Darwin
import Foundation
import AppKit
import HermesKit
import SwiftUI

/// One local command at a time, across every frame type.
///
/// The GUI lock inside `ComputerActions` only serialises desktop gestures. Two `execute` frames, or
/// an `observe` racing a `file` write, used to run concurrently because each frame got its own Task.
/// This gate is the single queue every frame passes through, so the order the bridge sent is the
/// order this Mac works.
private actor CommandGate {
    private var queue: [() async -> Void] = []
    private var running = false

    func run(_ operation: @escaping () async -> Void) async {
        queue.append(operation)
        guard !running else { return }
        running = true
        while !queue.isEmpty {
            let next = queue.removeFirst()
            await next()
        }
        running = false
    }
}

/// One row of Settings → Computer → Activity: what ran, who asked, and how it ended.
struct ComputerActivityItem: Identifiable, Equatable {
    let id: UUID
    let at: Date
    let bot: String
    let kind: String
    let summary: String
    let outcome: String
    let durationMS: Int?
}

/// What the host reports about the instructions it writes for its agents.
///
/// One row in Settings → Computer comes from this: whether every agent on the host can already see
/// how to reach this Mac, and whether what they have is the current set of instructions. Absent
/// (`nil`) means the host did not answer — never "not installed", which the host states explicitly.
struct ComputerSkillStatus: Equatable, Sendable {
    var version: String
    var present: Bool
    var upToDate: Bool
    /// The owner wrote a skill by that name, so the host leaves it alone and never overwrites it.
    var ownedByTheUser: Bool
    /// The command line the skill tells agents to run. Missing means the row is telling a lie.
    var cliPresent: Bool
}

/// The Mac half of local computer use: one outbound, authenticated socket to the bridge.
///
/// Nothing listens on this Mac — no SSH, no Remote Login, no inbound port. The socket is dialed from
/// here with a per-connection ticket and re-dialed with exponential backoff, so a laptop that sleeps,
/// changes networks or is restarted comes back on its own. The toggle is off by default and revoking
/// a computer on the host closes its socket and refuses the next one.
@MainActor
final class LocalComputerService: ObservableObject {
    /// One executor per process. A view-scoped service kept a live socket when its Settings window
    /// closed, then a fresh window dialed a second one and the two registrations fought on the bridge.
    static let shared = LocalComputerService()

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
    @Published private(set) var computerActions = 0
    @Published private(set) var lastCommand: String?
    @Published private(set) var recentActivity: [ComputerActivityItem] = []
    @Published private(set) var liveOutput = ""
    @Published private(set) var isCommandRunning = false
    /// The host's answer about the bot instructions, and whether one arrived at all.
    @Published private(set) var skill: ComputerSkillStatus?
    @Published private(set) var skillChecked = false
    @Published private(set) var skillBusy = false

    private let defaults = UserDefaults.standard
    private let enabledKey = "hermey.localComputer.enabled"
    private var enabled = false
    private var loop: Task<Void, Never>?
    private var loopRunning = false
    private var loopGeneration = 0
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var heartbeat: Task<Void, Never>?
    private var lastPong = Date()
    /// When the ping still waiting for a pong was sent; `nil` means nothing is outstanding.
    ///
    /// This is what stops a suspended app from reading its own silence as a dead socket: walk-away
    /// silence between pings says nothing about the link, while a ping that goes unanswered does.
    private var pingSentAt: Date?
    /// Kept so a wake or an app activation can restart a loop that has already finished.
    private var address: PairingAddress?
    private var wakeObservers: [NSObjectProtocol] = []
    private let commandGate = CommandGate()
    private var takeoverCancellable: AnyCancellable?

    /// The machine name shown on the host's Computers list.
    private let machineName = Host.current().localizedName ?? "Mac"

    init() {
        enabled = defaults.bool(forKey: enabledKey)
        if enabled { status = .connecting }
        // The tap lives in `ComputerTakeover`; this is only the feed's observer, so the row appears
        // the moment a human touches the machine rather than when the next action checks the gate.
        takeoverCancellable = ComputerTakeover.shared.$active
            .removeDuplicates()
            .sink { [weak self] active in
                if active {
                    self?.recordActivity(bot: "owner", kind: "takeover",
                                          summary: "Physical input detected",
                                          outcome: "paused")
                }
            }
        // Waking is the moment a socket most often comes back dead: the Mac slept, the transport is
        // gone, and nothing tells us. Verify on wake and on becoming active rather than waiting for
        // the owner to notice the switch is on and the host cannot reach the machine.
        wakeObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.recoverIfNeeded() }
            }
        )
        wakeObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.recoverIfNeeded() }
            }
        )
    }

    deinit {
        for observer in wakeObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    var isEnabled: Bool { enabled }

    /// Append one row to the activity feed, keeping the newest hundred.
    private func recordActivity(bot: String, kind: String, summary: String,
                                outcome: String, durationMS: Int? = nil) {
        let item = ComputerActivityItem(id: UUID(), at: Date(), bot: bot, kind: kind,
                                        summary: summary, outcome: outcome,
                                        durationMS: durationMS)
        recentActivity.append(item)
        if recentActivity.count > 100 {
            recentActivity.removeFirst(recentActivity.count - 100)
        }
    }

    /// Keep the tail of a running command's output for the Activity pane.
    private func appendLiveOutput(stdout: String, stderr: String) {
        var piece = ""
        if !stdout.isEmpty { piece += stdout }
        if !stderr.isEmpty { piece += stderr }
        guard !piece.isEmpty else { return }
        liveOutput += piece
        if liveOutput.count > 4_000 {
            liveOutput = String(liveOutput.suffix(4_000))
        }
    }

    func setEnabled(_ value: Bool, address: PairingAddress?) {
        enabled = value
        defaults.set(value, forKey: enabledKey)
        self.address = address
        if value {
            guard let address else {
                loop?.cancel()
                loop = nil
                loopRunning = false
                drop(socket)
                status = .refused
                lastError = "Pair this Mac with a host before enabling local computer use."
                return
            }
            lastError = nil
            status = .connecting
            loop?.cancel()
            loopGeneration += 1
            let generation = loopGeneration
            loopRunning = true
            loop = Task { await connectionLoop(address: address, generation: generation) }
        } else {
            loop?.cancel()
            loop = nil
            loopRunning = false
            drop(socket)
            ComputerTakeover.shared.stop()
            status = .off
        }
    }

    /// Re-verify the link after the machine wakes or the app comes forward.
    ///
    /// A suspended socket returns looking connected and answers nothing, and the app used to sit in
    /// that state until the owner flipped the switch. Now the wake either gets a pong or the socket is
    /// dropped and reconnected by the loop. A genuine revoke is left alone: that needs the owner.
    func recoverIfNeeded() {
        guard enabled, status != .refused else { return }
        guard let socket else {
            ensureConnected()
            return
        }
        sendPing(on: socket)
    }

    /// Restart the connection loop when it is not running (it exits on a revoked pairing).
    private func ensureConnected() {
        guard enabled, status != .refused, !loopRunning, let address else { return }
        ClientLog.shared.record("local computer reconnecting after wake", category: "local-computer")
        status = .connecting
        loopGeneration += 1
        let generation = loopGeneration
        loopRunning = true
        loop = Task { await connectionLoop(address: address, generation: generation) }
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

    /// Ask the host to lift a revoke. Called when the computer-use switch goes back on.
    ///
    /// The trash button revokes this Mac on the host, and the switch used to do nothing about it:
    /// turning it back on re-dialled into a rejected handshake forever. Removing a computer is a
    /// decision about that moment; turning the switch on is the opposite decision, and the host
    /// has a route for it — the same per-call ticket as the revoke.
    func allow(address: PairingAddress?) async {
        guard let address, !address.isTicketOnly,
              let ticket = try? await address.mintedTicket(),
              let origin = try? address.apiOrigin() else { return }
        var request = URLRequest(
            url: origin.appendingPathComponent("v1/local-computers/\(address.deviceID)/enable"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(ticket)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Ask the host where the bot instructions are. Read-only on the host by design: looking must
    /// never install anything.
    func refreshSkill(address: PairingAddress?) async {
        defer { skillChecked = true }
        guard let request = await skillRequest(method: "GET", address: address),
              let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // No answer is not "not installed": the row says unavailable and offers the button.
            skill = nil
            return
        }
        skill = ComputerSkillStatus(
            version: object["version"] as? String ?? "",
            present: object["present"] as? Bool ?? false,
            upToDate: object["up_to_date"] as? Bool ?? false,
            ownedByTheUser: (object["owned_by_the_user"] as? [Any])?.isEmpty == false,
            cliPresent: object["cli_present"] as? Bool ?? false
        )
    }

    /// Re-run the host's own installer — the same pass it makes on every start.
    func installSkill(address: PairingAddress?) async {
        guard !skillBusy else { return }
        skillBusy = true
        defer { skillBusy = false }
        if let request = await skillRequest(method: "POST", address: address) {
            _ = try? await URLSession.shared.data(for: request)
        }
        await refreshSkill(address: address)
    }

    /// Both skill routes take the same per-call ticket the revoke uses; there is no long-lived token.
    private func skillRequest(method: String, address: PairingAddress?) async -> URLRequest? {
        guard let address, !address.isTicketOnly,
              let ticket = try? await address.mintedTicket(),
              let origin = try? address.apiOrigin() else { return nil }
        var request = URLRequest(url: origin.appendingPathComponent("v1/local-computers/skill"))
        request.httpMethod = method
        request.setValue("Bearer \(ticket)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Called when the pairing changes: a live socket belongs to the old host's ticket.
    func pairingChanged(address: PairingAddress?) {
        guard enabled else { return }
        setEnabled(true, address: address)
    }

    /// The owner pressed Resume after a takeover. The bridge frame and the menu-bar button both
    /// land here, so the feed records the hand-back once, from one place.
    func resumeAfterTakeover() {
        ComputerTakeover.shared.resume()
        recordActivity(bot: "owner", kind: "resume",
                        summary: "Control handed back", outcome: "resumed")
    }

    private struct LocalComputerCloseError: Error {
        let code: Int
        let underlying: Error
    }

    // MARK: - Connection

    private func connectionLoop(address: PairingAddress, generation: Int) async {
        var backoff: UInt64 = 1_000_000_000
        // Only the newest loop owns the flag: `setEnabled` cancels and starts one, and the cancelled
        // loop's exit must not mark the new one as not running.
        defer { if loopGeneration == generation { loopRunning = false } }
        while !Task.isCancelled, enabled {
            do {
                try await connectOnce(address: address)
                backoff = 1_000_000_000
            } catch {
                if Task.isCancelled { break }
                let code = (error as? LocalComputerCloseError)?.code
                ClientLog.shared.record("local computer reconnecting: code=\(code ?? -1) \(error.localizedDescription)",
                                        level: .warning, category: "local-computer")
                if code == 4400 {
                    // The host accepted a newer socket for this Mac and closed this one. A retry
                    // would evict the replacement in turn, and the two would trade the registration
                    // for ever. Status is left alone: the newer loop owns it.
                    ClientLog.shared.record(
                        "local computer socket replaced by a newer connection; standing down",
                        level: .info, category: "local-computer")
                    break
                }
                if code == 4403 {
                    // A revoke is the owner's decision. Stop and say so instead of hammering the host.
                    status = .refused
                    // True now that the host has an enable route and this switch calls it; when the
                    // handshake was rejected before accept this message could never appear at all.
                    lastError = "Access was removed on the host. Turn this switch off and on to ask for it again."
                    break
                }
                // 4401 is a rejected *ticket*, not a verdict on this Mac: it was consumed, it expired,
                // or it was minted for a device the host no longer knows. Breaking the loop here is
                // what left the owner flipping the switch — every attempt mints a fresh ticket.
                status = .reconnecting
                lastError = code == 4401
                    ? "The host refused the pairing ticket; reconnecting."
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
        pingSentAt = nil
        ComputerTakeover.shared.start()
        ClientLog.shared.record("local computer socket connected", category: "local-computer")

        // One heartbeat, one receive loop. This used to be a `Timer` that dropped the socket whenever
        // `lastPong` was older than 60 s — but a backgrounded macOS app has its timers throttled, so
        // that clock aged while nothing was being sent and the app tore down a healthy socket on wake.
        // That is the churn in the bridge's audit log (disconnect and reconnect in the same second).
        // Silence only counts now if a ping was actually sent and went unanswered.
        let beat = startHeartbeat(for: task)
        do {
            try await receiveFrames(on: task)
            if Task.isCancelled {
                // This loop was replaced — a toggle, a re-dial after wake, a fresh ticket. Leaving
                // the socket open would let the host accept it as a second live registration and
                // close the *newer* one with 4400, which the newer loop then treats as a drop. That
                // is the ~20 s reconnect churn in the bridge's audit log, and it killed a two-minute
                // build halfway. A replaced loop closes what it was holding.
                drop(task)
                return
            }
            finish(task)
        } catch {
            // URLSession never throws the peer's close code. It is on the task after the failure,
            // so read it before cancel() clears the transport.
            let code = task.closeCode.rawValue
            finish(task)
            throw LocalComputerCloseError(code: code, underlying: error)
        }
        _ = beat
    }

    /// Ping every 15 s and drop the link only when a *sent* ping goes unanswered for 45 s.
    private func startHeartbeat(for task: URLSessionWebSocketTask) -> Task<Void, Never> {
        heartbeat?.cancel()
        let beat = Task { @MainActor [weak self, weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, let task, self.socket === task else { return }
                if let sent = self.pingSentAt, Date().timeIntervalSince(sent) > 45 {
                    self.drop(task)
                    return
                }
                self.sendPing(on: task)
            }
        }
        heartbeat = beat
        return beat
    }

    /// One ping, with one outstanding at a time: `pingSentAt` is the deadline the heartbeat measures.
    private func sendPing(on task: URLSessionWebSocketTask) {
        guard socket === task else { return }
        if pingSentAt == nil { pingSentAt = Date() }
        task.send(.string(#"{"type":"ping"}"#)) { [weak self, weak task] error in
            guard error != nil, let self, let task else { return }
            Task { @MainActor [weak self, weak task] in
                guard let self, let task else { return }
                self.drop(task)
            }
        }
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
                pingSentAt = nil
                continue
            }
            if kind == "ping" {
                // The bridge pings too now, so it can tell a live Mac from a socket that outlived its
                // machine. Answer it the same way it answers ours.
                task.send(.string(#"{"type":"pong"}"#)) { _ in }
                continue
            }
            if kind == "execute" {
                // Never await a command inside the receive loop: doing that stopped us reading the
                // bridge's pongs for the whole build, which made the link look dead and dropped it.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.commandGate.run { [weak self] in
                        guard let self else { return }
                        await self.handleExecute(frame, on: task)
                    }
                }
            } else if kind == "observe" {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.commandGate.run { [weak self] in
                        guard let self else { return }
                        await self.handleObserve(frame, on: task)
                    }
                }
            } else if kind == "act" {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.commandGate.run { [weak self] in
                        guard let self else { return }
                        await self.handleAct(frame, on: task)
                    }
                }
            } else if kind == "file" {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.commandGate.run { [weak self] in
                        guard let self else { return }
                        await self.handleFile(frame, on: task)
                    }
                }
            } else if kind == "browser" {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.commandGate.run { [weak self] in
                        guard let self else { return }
                        await self.handleBrowser(frame, on: task)
                    }
                }
            } else if kind == "resume" {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleResume(frame, on: task)
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
        heartbeat?.cancel()
        heartbeat = nil
        pingSentAt = nil
        socket = nil
        ComputerTakeover.shared.stop()
        task.cancel(with: .goingAway, reason: nil)
    }

    private func finish(_ task: URLSessionWebSocketTask) {
        heartbeat?.cancel()
        heartbeat = nil
        pingSentAt = nil
        if socket === task { socket = nil }
        task.cancel(with: .goingAway, reason: nil)
        if status == .connected { status = .reconnecting }
    }

    // MARK: - Commands

    private func handleExecute(_ frame: [String: Any], on task: URLSessionWebSocketTask) async {
        guard let id = frame["id"] as? String,
              let argv = frame["argv"] as? [String], !argv.isEmpty else { return }
        let cwd = frame["cwd"] as? String
        let timeout = frame["timeout_ms"] as? Int ?? 60_000
        let callID = id
        let started = Date()
        isCommandRunning = true
        liveOutput = ""
        defer { isCommandRunning = false }
        // Progress goes to two places at once: the bridge (for a streaming caller on the host) and
        // this app's own Activity pane (for the owner watching the Mac). The socket send is
        // thread-safe, so the reporter can be driven straight from the pipe's reader threads.
        let reporter = ProgressReporter(task: task, id: callID) { [weak self] stdout, stderr in
            Task { @MainActor [weak self] in
                self?.appendLiveOutput(stdout: stdout, stderr: stderr)
            }
        }
        let result = await Task.detached(priority: .userInitiated) {
            LocalProcess.run(argv: argv, cwd: cwd, timeoutMS: timeout) { stdout, stderr in
                reporter.append(stdout: stdout, stderr: stderr)
            }
        }.value
        reporter.finish()
        guard !Task.isCancelled else { return }
        commandsRun += 1
        lastCommand = argv.joined(separator: " ")
        let durationMS = Int(Date().timeIntervalSince(started) * 1_000)
        let outcome = result.exitCode == 0 ? "ok" : "exit \(result.exitCode)"
        recordActivity(bot: "host", kind: "execute",
                      summary: argv.joined(separator: " "),
                      outcome: outcome, durationMS: durationMS)
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

    private func handleBrowser(_ frame: [String: Any], on task: URLSessionWebSocketTask) async {
        guard let id = frame["id"] as? String,
              let op = frame["op"] as? String else { return }
        let started = Date()
        do {
            let result: [String: Any]
            switch op {
            case "navigate":
                guard let url = frame["url"] as? String else { throw BrowserError.badURL }
                result = try await ComputerBrowser.shared.navigate(url)
            case "snapshot":
                result = try await ComputerBrowser.shared.snapshot()
            case "act":
                guard let actions = frame["actions"] as? [[String: Any]] else { throw BrowserError.badBatch }
                result = try await ComputerBrowser.shared.act(actions)
            case "downloads":
                result = ["downloads": ComputerBrowser.shared.recentDownloads()]
            default:
                throw BrowserError.badBatch
            }
            let durationMS = Int(Date().timeIntervalSince(started) * 1_000)
            recordActivity(bot: "host", kind: "browser", summary: op,
                           outcome: "ok", durationMS: durationMS)
            ClientLog.shared.record("computer browser \(op)", category: "local-computer")
            sendReply(["id": id, "type": "result", "exit_code": 0, "browser": result], on: task)
        } catch {
            recordActivity(bot: "host", kind: "browser", summary: op,
                           outcome: "failed")
            sendReply(["id": id, "type": "result", "exit_code": 1,
                       "error": error.localizedDescription], on: task)
        }
    }

    private func handleFile(_ frame: [String: Any], on task: URLSessionWebSocketTask) async {
        guard let id = frame["id"] as? String else { return }
        let op = frame["op"] as? String ?? "?"
        let path = frame["path"] as? String ?? ""
        let started = Date()
        do {
            let result = try await Task.detached(priority: .utility) {
                try ComputerFiles.shared.perform(frame)
            }.value
            let durationMS = Int(Date().timeIntervalSince(started) * 1_000)
            recordActivity(bot: "host", kind: "file", summary: "\(op) \(path)",
                           outcome: "ok", durationMS: durationMS)
            ClientLog.shared.record("computer file \(op)",
                                    category: "local-computer")
            sendReply(["id": id, "type": "result", "exit_code": 0, "file": result], on: task)
        } catch {
            recordActivity(bot: "host", kind: "file", summary: "\(op) \(path)",
                           outcome: "failed")
            sendReply(["id": id, "type": "result", "exit_code": 1,
                       "error": error.localizedDescription], on: task)
        }
    }

    private func handleAct(_ frame: [String: Any], on task: URLSessionWebSocketTask) async {
        guard let id = frame["id"] as? String,
              let actions = frame["actions"] as? [[String: Any]] else { return }
        let bot = frame["bot"] as? String ?? "unknown"
        let started = Date()
        do {
            let observation = try await ComputerActions.shared.perform(actions, bot: bot)
            computerActions += actions.count
            lastCommand = "act(\(actions.count)) by \(bot)"
            let durationMS = Int(Date().timeIntervalSince(started) * 1_000)
            recordActivity(bot: bot, kind: "act",
                            summary: "\(actions.count) action(s)",
                            outcome: "ok", durationMS: durationMS)
            ClientLog.shared.record("computer act by \(bot): \(actions.count) action(s)",
                                    category: "local-computer")
            guard let data = try? JSONEncoder().encode(observation),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                sendReply(["id": id, "type": "result", "error": "observation encoding failed"], on: task)
                return
            }
            sendReply(["id": id, "type": "result", "exit_code": 0,
                       "observation": object, "stderr": "", "truncated": false], on: task)
        } catch {
            recordActivity(bot: bot, kind: "act",
                            summary: "\(actions.count) action(s)",
                            outcome: "failed")
            sendReply(["id": id, "type": "result", "exit_code": 1,
                       "error": error.localizedDescription], on: task)
        }
    }

    private func handleObserve(_ frame: [String: Any], on task: URLSessionWebSocketTask) async {
        guard let id = frame["id"] as? String else { return }
        let started = Date()
        let result = await Task.detached(priority: .userInitiated) {
            Result<ComputerObservation, Error> { try ComputerObserver.shared.observe() }
        }.value
        switch result {
        case .success(let observation):
            ComputerActions.shared.noteObservation()
            let durationMS = Int(Date().timeIntervalSince(started) * 1_000)
            recordActivity(bot: "host", kind: "observe", summary: "screen captured",
                           outcome: "ok", durationMS: durationMS)
            guard let data = try? JSONEncoder().encode(observation),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                sendReply(["id": id, "type": "result", "error": "observation encoding failed"], on: task)
                return
            }
            sendReply(["id": id, "type": "result", "exit_code": 0,
                       "observation": object, "stderr": "", "truncated": false], on: task)
        case .failure(let error):
            recordActivity(bot: "host", kind: "observe", summary: "screen capture",
                           outcome: "failed")
            sendReply(["id": id, "type": "result", "exit_code": 1,
                       "error": error.localizedDescription], on: task)
        }
    }

    /// The owner handed control back after a takeover. Nothing else in the batch moves until this.
    private func handleResume(_ frame: [String: Any], on task: URLSessionWebSocketTask) {
        guard let id = frame["id"] as? String else { return }
        resumeAfterTakeover()
        sendReply(["id": id, "type": "result", "exit_code": 0], on: task)
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

    static func run(argv: [String], cwd: String?, timeoutMS: Int,
                    onChunk: ((Data, Data) -> Void)? = nil) -> LocalProcessResult {
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
            lock.lock()
            if outData.count + piece.count <= maxOutput { outData.append(piece) } else { truncated = true }
            lock.unlock()
            onChunk?(piece, Data())
        }
        err.fileHandleForReading.readabilityHandler = { source in
            let piece = source.availableData
            guard !piece.isEmpty else { return }
            lock.lock()
            if errData.count + piece.count <= maxOutput { errData.append(piece) } else { truncated = true }
            lock.unlock()
            onChunk?(Data(), piece)
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
