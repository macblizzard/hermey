import Foundation

/// Newline-delimited JSON-RPC 2.0, which is the wire format of the Hermes TUI
/// gateway (``tui_gateway/ws.py`` on the host). Every frame is one JSON object on
/// one line, in both directions; the gateway sends ``gateway.ready`` right after
/// the socket opens.
public enum JSONRPCVersion {
    public static let string = "2.0"
}

// MARK: - Identifier

/// A JSON-RPC id is a number or a string. Hermes uses both: integer ids for calls,
/// string ids (``srq-7``) for the requests the *server* sends the client.
public enum RPCID: Hashable, Sendable, Codable {
    case int(Int64)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int64.self) { self = .int(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "id must be an integer or a string")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }
}

extension RPCID: CustomStringConvertible {
    public var description: String {
        switch self {
        case .int(let v): return String(v)
        case .string(let v): return v
        }
    }
}

// MARK: - Any JSON

/// A tolerant JSON value, so the client never fails on a field Hermes adds later.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int64.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
}

// MARK: - Error

public struct RPCError: Error, Hashable, Sendable, Codable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// The answer a client gives to a server request it does not implement. Hermes
    /// fails the agent fast on this instead of waiting out a timeout.
    public static let methodNotFound = RPCError(code: -32601, message: "Method not found")
    public static let invalidParams = RPCError(code: -32602, message: "Invalid params")
    public static let internalError = RPCError(code: -32603, message: "Internal error")
    /// Hermes' own "session busy" code, used when a rewind lands mid-turn.
    public static let sessionBusy = RPCError(code: 4009, message: "session busy")
}

// MARK: - Frames

public struct RPCRequest: Encodable, Sendable {
    /// Always `"2.0"`. Declared as a stored property so the synthesized encoder writes it —
    /// the gateway rejects a frame without it, and the first CI run proved that.
    private let jsonrpc = JSONRPCVersion.string
    public let id: RPCID
    public let method: String
    public let params: JSONValue?


    public init(id: RPCID, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// An answer to a request the *server* sent us.
public struct RPCResponse: Encodable, Sendable {
    private let jsonrpc = JSONRPCVersion.string
    public let id: RPCID
    public let result: JSONValue?
    public let error: RPCError?


    public init(id: RPCID, result: JSONValue? = nil, error: RPCError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
}

/// Anything that arrives on the socket.
public enum IncomingFrame: Sendable {
    /// A response to one of our requests.
    case response(id: RPCID, result: JSONValue?, error: RPCError?)
    /// A request *from* the gateway that we must answer: approval, clarify, sudo,
    /// secret, vault.code, terminal.read, preview.act, tour.
    case request(RPCRequest)
    /// A notification, which is how every streamed event arrives.
    case notification(method: String, params: JSONValue)
}

public enum JSONRPCError: Error, Sendable {
    case malformedFrame(String)
}

// MARK: - Codec

public enum JSONRPCCodec {
    /// Decode is deliberately permissive: an unknown event, a null id or an
    /// unexpected field must never kill the connection, because Hermes ships new
    /// event kinds between our releases.
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    public static func encodeToString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let s = String(data: data, encoding: .utf8) else {
            throw JSONRPCError.malformedFrame("not UTF-8")
        }
        return s
    }

    public static func encodeFrame<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A) // newline delimits frames
        return data
    }

    /// Decode one line into whichever frame shape it is.
    public static func decodeLine(_ line: Data) throws -> IncomingFrame? {
        let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
        guard !trimmed.isEmpty else { return nil }
        guard let obj = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed)) else {
            throw JSONRPCError.malformedFrame(String(data: trimmed, encoding: .utf8) ?? "<binary>")
        }
        guard let dict = obj.objectValue else {
            throw JSONRPCError.malformedFrame("frame is not an object")
        }
        let idValue = dict["id"].flatMap { $0 == .null ? nil : $0 }
        let method = dict["method"]?.stringValue

        if let method {
            let params = dict["params"]
            if let idValue {
                let id = (try? JSONDecoder().decode(RPCID.self, from: JSONEncoder().encode(idValue)))
                    ?? .string(String(describing: idValue))
                return .request(RPCRequest(id: id, method: method, params: params))
            }
            return .notification(method: method, params: params ?? .null)
        }

        guard let idValue,
              let id = try? JSONDecoder().decode(RPCID.self, from: JSONEncoder().encode(idValue))
        else {
            throw JSONRPCError.malformedFrame("neither request nor response")
        }
        let err: RPCError? = {
            guard let e = dict["error"], e != .null,
                  let data = try? JSONEncoder().encode(e) else { return nil }
            return try? JSONDecoder().decode(RPCError.self, from: data)
        }()
        return .response(id: id, result: dict["result"], error: err)
    }
}

/// Splits a byte stream into newline-delimited frames. Keeps the tail of a partial
/// frame so a chunk boundary in the middle of a token is not a parse error.
public struct NDJSONBuffer: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<index]
            frames.append(Data(line))
            buffer = buffer[buffer.index(after: index)...]
        }
        return frames
    }

    public var pending: Data { buffer }
}
