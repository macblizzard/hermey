import Foundation

/// A bot's own generated avatar, in the `open-bot-avatar` v1 definition format.
///
/// The format is somebody else's, on purpose: a definition is a single monochrome SVG path in a
/// fixed `0 0 100 100` box plus the placement of an eye pair, and it contains no colour, no motion
/// and no raster image. A JSON pasted from <https://github.com/DominikScholz/open-bot-avatar>'s
/// editor imports unchanged, and one written here can be pasted back there.
///
/// ```json
/// {"version":1,"id":"box","name":"Box",
///  "body":{"path":"M20 20 H80 V80 H20 Z"},
///  "eyes":{"x":50,"y":46,"spacing":15,"scale":1}}
/// ```
///
/// Decoding is strict, as upstream's validator is: an unknown field is an error rather than
/// something silently dropped, because a definition whose meaning depends on which fields a reader
/// happens to know is a definition that draws differently on two devices.
public struct BotAvatarDefinition: Hashable, Sendable, Codable {
    /// Where the eyes sit on the body, in definition units.
    public struct Eyes: Hashable, Sendable, Codable {
        /// Centre of the pair.
        public var x: Double
        public var y: Double
        /// Centre to centre.
        public var spacing: Double
        /// 1 means each neutral eye is about 4 units wide and 11 tall.
        public var scale: Double

        public init(x: Double, y: Double, spacing: Double, scale: Double) {
            self.x = x
            self.y = y
            self.spacing = spacing
            self.scale = scale
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: BotAvatarDefinition.AnyKey.self)
            try BotAvatarDefinition.rejectUnknown(container, allowed: BotAvatarDefinition.eyeKeys, prefix: "eyes")
            x = try container.decode(Double.self, forKey: .init("x"))
            y = try container.decode(Double.self, forKey: .init("y"))
            spacing = try container.decode(Double.self, forKey: .init("spacing"))
            scale = try container.decode(Double.self, forKey: .init("scale"))
        }
    }

    /// The one filled path. Holes are subpaths wound the other way (nonzero fill).
    public struct Body: Hashable, Sendable, Codable {
        public var path: String
        public init(path: String) { self.path = path }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: BotAvatarDefinition.AnyKey.self)
            let unknown = container.allKeys.map(\.stringValue).filter { $0 != "path" }
            if let first = unknown.first {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: container.codingPath,
                    debugDescription: "unknown field \"body.\(first)\" (only \"path\" is allowed)"))
            }
            path = try container.decode(String.self, forKey: .init("path"))
        }
    }

    public var version: Int
    /// A lowercase slug: the definition's identity, not the bot's.
    public var id: String
    /// A short display name.
    public var name: String
    public var body: Body
    public var eyes: Eyes

    public init(version: Int = 1, id: String, name: String, body: Body, eyes: Eyes) {
        self.version = version
        self.id = id
        self.name = name
        self.body = body
        self.eyes = eyes
    }

    /// The contract's field set, and nothing else.
    public static let topLevelKeys = ["version", "id", "name", "body", "eyes"]
    public static let eyeKeys = ["x", "y", "spacing", "scale"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        try Self.rejectUnknown(container, allowed: Self.topLevelKeys, prefix: nil)
        version = try container.decode(Int.self, forKey: AnyKey("version"))
        id = try container.decode(String.self, forKey: AnyKey("id"))
        name = try container.decode(String.self, forKey: AnyKey("name"))
        body = try container.decode(Body.self, forKey: AnyKey("body"))
        eyes = try container.decode(Eyes.self, forKey: AnyKey("eyes"))
        // `body` and `eyes` reject extra keys the same way, through their own decoders.
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(version, forKey: AnyKey("version"))
        try container.encode(id, forKey: AnyKey("id"))
        try container.encode(name, forKey: AnyKey("name"))
        try container.encode(body, forKey: AnyKey("body"))
        try container.encode(eyes, forKey: AnyKey("eyes"))
    }

    /// Refuse a field the contract does not define, naming it and the ones that are allowed.
    static func rejectUnknown(_ container: KeyedDecodingContainer<AnyKey>,
                                              allowed: [String],
                                              prefix: String?) throws {
        let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }
        if let first = unknown.first {
            let name = prefix.map { "\($0).\(first)" } ?? first
            let hint = prefix == nil
                ? "allowed: \(allowed.joined(separator: ", "))"
                : "allowed: \(allowed.map { "\(prefix ?? "").\($0)" }.joined(separator: ", "))"
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "unknown field \"\(name)\" (\(hint))"))
        }
    }

    /// A `CodingKey` built from a string, for the strict unknown-field pass.
    public struct AnyKey: CodingKey, Hashable, Sendable {
        public var stringValue: String
        public var intValue: Int? { nil }
        public init(_ string: String) { stringValue = string }
        public init?(stringValue: String) { self.stringValue = stringValue }
        public init?(intValue: Int) { nil }
    }

    /// The body's path, read into polygons. Throws the parser's own error.
    public func polygons() throws -> [[OpenBotAvatarGeometry.Point]] {
        OpenBotAvatarGeometry.polygons(try OpenBotAvatarGeometry.parse(body.path))
    }

    /// The body's ink box, once the path has been read.
    public func bodyBox() throws -> OpenBotAvatarGeometry.Box {
        let polygons = try polygons()
        guard !polygons.isEmpty else { throw OpenBotAvatarGeometry.PathError.nothingToDraw }
        return OpenBotAvatarGeometry.Box(polygons.flatMap { $0 })
    }
}

// MARK: - Validation

/// Why a definition cannot be drawn.
///
/// Upstream returns a list of sentences, and so does this: a paste usually has one mistake and a
/// reader who can see all of them at once fixes it in one pass. The strings are the contract's own,
/// so the editor's message and the host's 400 say the same thing.
public struct BotAvatarValidationFailure: Error, Hashable, Sendable, CustomStringConvertible {
    public var errors: [String]
    public init(_ errors: [String]) { self.errors = errors }
    public var description: String { errors.joined(separator: "\n") }
    /// The one line a compact surface shows.
    public var summary: String { errors.first ?? "invalid avatar definition" }
}

public extension BotAvatarDefinition {

    /// Hard bounds of the body's geometry: the safe area inside the 0..100 box.
    static let bodyMin = 6.0
    static let bodyMax = 94.0
    /// The soft target the contract asks a generator for (8..92), named here for its message.
    static let bodyTarget = 8.0

    /// Check a definition against the contract, returning it normalised, or every reason it fails.
    ///
    /// The rules, in the contract's order: the field set; `version` is 1; `id` is a slug; `name` is
    /// short and printable; `body.path` parses, stays in the safe area, is big enough to carry a
    /// face and has enough area behind the eyes; the eyes' scale and spacing are in range; and both
    /// eyes, at their drawn size plus a margin, sit inside the filled body.
    ///
    /// It is `throws` rather than returning a result type because every caller either draws the
    /// value or shows the message — there is no third use.
    func validated() throws -> BotAvatarDefinition {
        var errors: [String] = []

        if version != 1 { errors.append("version must be 1") }
        if !Self.isSlug(id) {
            errors.append("id must be a lowercase slug of 1-40 chars [a-z0-9-]")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName.count > 40
            || trimmedName.contains("<") || trimmedName.contains(">")
            || trimmedName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            errors.append("name must be 1-40 printable characters without < or >")
        }

        var polygons: [[OpenBotAvatarGeometry.Point]] = []
        var box: OpenBotAvatarGeometry.Box?
        do {
            polygons = try self.polygons()
            if polygons.isEmpty { throw OpenBotAvatarGeometry.PathError.nothingToDraw }
            box = OpenBotAvatarGeometry.Box(polygons.flatMap { $0 })
        } catch let error as OpenBotAvatarGeometry.PathError {
            errors.append("body.path: \(error.description)")
        } catch {
            errors.append("body.path: \(error.localizedDescription)")
        }

        let minSpacing = OpenBotAvatarGeometry.eyeWidth * eyes.scale * 1.75
        if eyes.scale < 0.6 || eyes.scale > 1.8 {
            errors.append("eyes.scale \(Self.round1(eyes.scale)) out of range 0.6..1.8")
        }
        if eyes.spacing < minSpacing || eyes.spacing > 40 {
            errors.append("eyes.spacing \(Self.round1(eyes.spacing)) out of range \(Self.round1(minSpacing))..40 for scale \(Self.round1(eyes.scale))")
        }
        if !(0...100).contains(eyes.x) || !(0...100).contains(eyes.y) {
            errors.append("eyes.x and eyes.y must be inside the 0 0 100 100 box")
        }

        if let box, !polygons.isEmpty {
            var outside: [String] = []
            if box.minX < Self.bodyMin { outside.append("left edge x=\(Self.round1(box.minX))") }
            if box.minY < Self.bodyMin { outside.append("top edge y=\(Self.round1(box.minY))") }
            if box.maxX > Self.bodyMax { outside.append("right edge x=\(Self.round1(box.maxX))") }
            if box.maxY > Self.bodyMax { outside.append("bottom edge y=\(Self.round1(box.maxY))") }
            if !outside.isEmpty {
                errors.append("body.path leaves the safe area (\(outside.joined(separator: ", "))); keep geometry within 8..92")
            }
            if max(box.width, box.height) < 40 || min(box.width, box.height) < 14 {
                errors.append("body is too small (\(Self.round1(box.width))x\(Self.round1(box.height))); use at least 40 units on the long side and 14 on the short side")
            }
            if OpenBotAvatarGeometry.filledArea(polygons) < 600 {
                errors.append("body fill area \(Self.round1(OpenBotAvatarGeometry.filledArea(polygons))) is too thin to carry eyes; must be at least 600 units²")
            }
            if !OpenBotAvatarGeometry.eyesFit(polygons, eyes: eyes, scale: eyes.scale, margin: OpenBotAvatarGeometry.eyeMargin) {
                errors.append("eyes must sit inside the body with \(OpenBotAvatarGeometry.eyeMargin) units margin; move eyes.x/y toward the widest solid area, reduce spacing or scale")
            }
        }

        guard errors.isEmpty else { throw BotAvatarValidationFailure(errors) }
        return BotAvatarDefinition(version: 1, id: id, name: trimmedName, body: body, eyes: eyes)
    }

    /// `^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$`, code point for code point.
    static func isSlug(_ value: String) -> Bool {
        let characters = Array(value)
        guard (1...40).contains(characters.count) else { return false }
        func allowed(_ character: Character) -> Bool {
            character.isASCII && (character.isLowercase || character.isNumber || character == "-")
        }
        guard allowed(characters[0]), characters[0] != "-" else { return false }
        guard allowed(characters[characters.count - 1]), characters[characters.count - 1] != "-" else { return false }
        return characters.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    static func round1(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}

// MARK: - Import

public extension BotAvatarDefinition {

    /// Read a definition pasted as JSON, so the editor can say exactly what is wrong with it.
    ///
    /// Three failures are distinguished because they need three different fixes: text that is not
    /// JSON at all, JSON that is not a definition (an unknown or missing field), and a definition
    /// whose geometry the contract refuses.
    static func decode(json text: String) throws -> BotAvatarDefinition {
        let data = Data(text.utf8)
        let definition: BotAvatarDefinition
        do {
            definition = try JSONDecoder().decode(BotAvatarDefinition.self, from: data)
        } catch let error as DecodingError {
            throw BotAvatarValidationFailure([Self.describe(error)])
        } catch {
            throw BotAvatarValidationFailure(["definition is not valid JSON: \(error.localizedDescription)"])
        }
        return try definition.validated()
    }

    /// A decoding error as one sentence a person can act on.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
        }
        switch error {
        case .dataCorrupted(let context):
            if let underlying = context.underlyingError as? BotAvatarValidationFailure {
                return underlying.summary
            }
            return "definition is not a valid avatar: \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            let where_ = path(context.codingPath)
            return "missing field \(where_.isEmpty ? key.stringValue : "\(where_).\(key.stringValue)")"
        case .typeMismatch(_, let context):
            let where_ = path(context.codingPath)
            return "\(where_.isEmpty ? "definition" : where_) has the wrong type"
        case .valueNotFound(_, let context):
            let where_ = path(context.codingPath)
            return "\(where_.isEmpty ? "definition" : where_) is null"
        @unknown default:
            return "definition could not be read"
        }
    }

    /// The JSON text to store: stable, unescaped slashes, one line.
    func jsonText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
