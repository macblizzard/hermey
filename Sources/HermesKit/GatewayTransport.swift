import Foundation

/// Minimal, dependency-free WebSocket transport for the Hermes TUI gateway.
///
/// Wire format: newline-delimited JSON-RPC 2.0 in both directions (see `JSONRPC.swift`).
/// Scope of this file in M0 is deliberately small — open a socket, decode frames into an
/// `AsyncStream`, send text. Request/response correlation and reconnect policy live in
/// `GatewayClient`.
public enum TransportState: Sendable, Equatable {
    case idle
    case connecting
    case open
    case reconnecting(attempt: Int)
    case closed(reason: String)
    case failed(String)
}

public enum TransportError: Error, Sendable {
    case notConnected
    case badURL(String)
}

#if canImport(Darwin)

public actor GatewayTransport {
    public typealias URLProvider = @Sendable () async throws -> URL

    public enum Event: Sendable {
        case state(TransportState)
        case frame(IncomingFrame)
        case malformed(String)
    }

    private let urlProvider: URLProvider
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private let continuation: AsyncStream<Event>.Continuation

    /// One consumer-visible stream of everything the socket does.
    public nonisolated let events: AsyncStream<Event>

    public init(urlProvider: @escaping URLProvider, session: URLSession = .shared) {
        self.urlProvider = urlProvider
        self.session = session
        var captured: AsyncStream<Event>.Continuation!
        self.events = AsyncStream<Event> { captured = $0 }
        self.continuation = captured
    }

    public func connect() async throws {
        continuation.yield(.state(.connecting))
        let url = try await urlProvider()
        let socket = session.webSocketTask(with: url)
        socket.resume()
        self.socket = socket
        continuation.yield(.state(.open))
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(on: socket)
        }
    }

    private func receiveLoop(on socket: URLSessionWebSocketTask) async {
        var buffer = NDJSONBuffer()
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: continue
                }
                for line in buffer.append(data) {
                    do {
                        if let frame = try JSONRPCCodec.decodeLine(line) {
                            continuation.yield(.frame(frame))
                        }
                    } catch {
                        continuation.yield(.malformed(String(describing: error)))
                    }
                }
            } catch {
                if !Task.isCancelled {
                    continuation.yield(.state(.failed(error.localizedDescription)))
                }
                return
            }
        }
    }

    public func send(text: String) async throws {
        guard let socket else { throw TransportError.notConnected }
        try await socket.send(.string(text))
    }

    public func send<T: Encodable>(_ frame: T) async throws {
        try await send(text: JSONRPCCodec.encodeToString(frame))
    }

    public func disconnect(reason: String = "client closed") {
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        continuation.yield(.state(.closed(reason: reason)))
    }
}

#else

/// Typecheck-only stand-in for platforms without `URLSessionWebSocketTask`.
///
/// The protocol core is pure Foundation and its tests drive a fake transport, so `swift build` on
/// Linux must still succeed — but there is no socket here. Every connection attempt fails loudly
/// instead of pretending to have one; the real path is Darwin-only and runs on the macOS runners.
public actor GatewayTransport {
    public typealias URLProvider = @Sendable () async throws -> URL

    public enum Event: Sendable {
        case state(TransportState)
        case frame(IncomingFrame)
        case malformed(String)
    }

    private let continuation: AsyncStream<Event>.Continuation
    public nonisolated let events: AsyncStream<Event>

    public init(urlProvider: @escaping URLProvider) {
        var captured: AsyncStream<Event>.Continuation!
        self.events = AsyncStream<Event> { captured = $0 }
        self.continuation = captured
    }

    public func connect() async throws {
        continuation.yield(.state(.failed("WebSocket transport is not available on this platform")))
        throw TransportError.notConnected
    }

    public func send(text: String) async throws {
        throw TransportError.notConnected
    }

    public func send<T: Encodable>(_ frame: T) async throws {
        try await send(text: JSONRPCCodec.encodeToString(frame))
    }

    public func disconnect(reason: String = "client closed") {
        continuation.yield(.state(.closed(reason: reason)))
    }
}

#endif
