import Foundation

/// Sends a command's output to the bridge while the command is still running.
///
/// The process writes into a pipe on a background thread, so this class is thread-safe and keeps
/// its own lock. Frames are coalesced: at most one every 250 ms, or when 64 KB has accumulated,
/// which is fast enough for an Xcode build to read as live and slow enough that the socket never
/// becomes the bottleneck.
final class ProgressReporter: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let id: String
    private let onText: (String, String) -> Void
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var lastFlush = Date.distantPast
    private var sequence = 0

    init(task: URLSessionWebSocketTask, id: String,
         onText: @escaping (String, String) -> Void) {
        self.task = task
        self.id = id
        self.onText = onText
    }

    /// A new piece from either pipe. Flushes when enough has arrived or enough time has passed.
    func append(stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        stdoutBuffer.append(stdout)
        stderrBuffer.append(stderr)
        if Date().timeIntervalSince(lastFlush) > 0.25
            || stdoutBuffer.count + stderrBuffer.count > 64 * 1024 {
            flushLocked()
        }
    }

    /// Send whatever is still buffered. Called once, after the process has exited.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        flushLocked()
    }

    private func flushLocked() {
        guard !stdoutBuffer.isEmpty || !stderrBuffer.isEmpty else { return }
        sequence += 1
        let stdout = stdoutBuffer
        let stderr = stderrBuffer
        stdoutBuffer = Data()
        stderrBuffer = Data()
        lastFlush = Date()
        let payload: [String: Any] = [
            "id": id,
            "type": "progress",
            "sequence": sequence,
            "stdout": stdout.base64EncodedString(),
            "stderr": stderr.base64EncodedString(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
        onText(String(data: stdout, encoding: .utf8) ?? "",
               String(data: stderr, encoding: .utf8) ?? "")
    }
}
