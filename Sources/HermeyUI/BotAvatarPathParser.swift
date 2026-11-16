import Foundation

/// One absolute command of an SVG path, in the avatar's own coordinate space.
///
/// The reference's shapes are drawn with a small subset of SVG (`M L C Q Z`), but the parser
/// accepts the whole pen-command family — `M/L/H/V/C/S/Q/T/Z`, absolute and relative — because a
/// path added to the set later must not need a new parser.
public enum BotAvatarPathCommand: Hashable, Sendable {
    case move(to: BotAvatarPoint)
    case line(to: BotAvatarPoint)
    case quad(control: BotAvatarPoint, to: BotAvatarPoint)
    case cubic(control1: BotAvatarPoint, control2: BotAvatarPoint, to: BotAvatarPoint)
    case close
}

/// Why a path string could not be read.
public enum BotAvatarPathError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The string held no commands at all.
    case empty
    /// A letter that is not an SVG command.
    case unknownCommand(Character)
    /// A number that could not be read where one was required.
    case malformedNumber(String)
    /// The pen moved before it was placed: a path must open with `M`.
    case missingInitialMove

    public var description: String {
        switch self {
        case .empty: return "path is empty"
        case .unknownCommand(let character): return "unknown path command \(character)"
        case .malformedNumber(let text): return "malformed number \(text)"
        case .missingInitialMove: return "path does not start with a move"
        }
    }
}

/// A small SVG path parser: enough for the shipped shapes and for anything drawn with the same pen.
///
/// It resolves every command to absolute coordinates, so a consumer never has to carry the current
/// point, and it mirrors SVG's rules that are easy to get wrong:
///
/// * extra coordinate pairs after `M` are implicit `L`s (relative ones stay relative),
/// * `S` and `T` reflect the previous control point of their own family, and use the current point
///   when the command before them was not of that family,
/// * `H` and `V` keep the other axis.
public enum BotAvatarPathParser {

    /// Every command in `data`, in order, with absolute coordinates.
    public static func parse(_ data: String) throws -> [BotAvatarPathCommand] {
        var scanner = Scanner(Array(data))
        var commands: [BotAvatarPathCommand] = []
        var current = BotAvatarPoint.zero
        var subpathStart = BotAvatarPoint.zero
        var lastCubicControl: BotAvatarPoint?
        var lastQuadControl: BotAvatarPoint?
        var placed = false
        var command: Character?

        while true {
            scanner.skipSeparators()
            guard let peeked = scanner.peek() else { break }
            if Self.isCommandLetter(peeked) {
                command = scanner.advance()
            } else if command == nil {
                throw BotAvatarPathError.missingInitialMove
            } else if !scanner.hasNumberAhead() {
                // A token that is neither a command nor a number: "M0 0 X10 10".
                throw BotAvatarPathError.unknownCommand(peeked)
            }

            guard let letter = command else { break }
            let family = Character(letter.uppercased())

            if family == "Z" {
                commands.append(.close)
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil
                command = nil
                // A number after a close has no command to belong to, and would loop forever.
                if scanner.hasNumberAhead() { throw BotAvatarPathError.malformedNumber(String(letter)) }
                continue
            }

            // Coordinates for one repetition of this command; a bare `M` repeats as `L`.
            var effective: Character = letter

            var readAny = false
            while scanner.hasNumberAhead() {
                let start = current
                let isRelative = effective.isLowercase
                switch Character(effective.uppercased()) {
                case "M":
                    let point = try scanner.point(relativeTo: isRelative ? start : nil)
                    current = point
                    subpathStart = point
                    commands.append(.move(to: point))
                    placed = true
                    lastCubicControl = nil
                    lastQuadControl = nil
                case "L":
                    let point = try scanner.point(relativeTo: isRelative ? start : nil)
                    current = point
                    commands.append(.line(to: point))
                    lastCubicControl = nil
                    lastQuadControl = nil
                case "H":
                    let value = try scanner.number()
                    let x = isRelative ? start.x + value : value
                    current = BotAvatarPoint(x, start.y)
                    commands.append(.line(to: current))
                    lastCubicControl = nil
                    lastQuadControl = nil
                case "V":
                    let value = try scanner.number()
                    let y = isRelative ? start.y + value : value
                    current = BotAvatarPoint(start.x, y)
                    commands.append(.line(to: current))
                    lastCubicControl = nil
                    lastQuadControl = nil
                case "C":
                    let c1 = try scanner.point(relativeTo: isRelative ? start : nil)
                    let c2 = try scanner.point(relativeTo: isRelative ? start : nil)
                    let end = try scanner.point(relativeTo: isRelative ? start : nil)
                    commands.append(.cubic(control1: c1, control2: c2, to: end))
                    current = end
                    lastCubicControl = c2
                    lastQuadControl = nil
                case "S":
                    let c1 = lastCubicControl.map { BotAvatarPoint(2 * start.x - $0.x, 2 * start.y - $0.y) } ?? start
                    let c2 = try scanner.point(relativeTo: isRelative ? start : nil)
                    let end = try scanner.point(relativeTo: isRelative ? start : nil)
                    commands.append(.cubic(control1: c1, control2: c2, to: end))
                    current = end
                    lastCubicControl = c2
                    lastQuadControl = nil
                case "Q":
                    let control = try scanner.point(relativeTo: isRelative ? start : nil)
                    let end = try scanner.point(relativeTo: isRelative ? start : nil)
                    commands.append(.quad(control: control, to: end))
                    current = end
                    lastQuadControl = control
                    lastCubicControl = nil
                case "T":
                    let control = lastQuadControl.map { BotAvatarPoint(2 * start.x - $0.x, 2 * start.y - $0.y) } ?? start
                    let end = try scanner.point(relativeTo: isRelative ? start : nil)
                    commands.append(.quad(control: control, to: end))
                    current = end
                    lastQuadControl = control
                    lastCubicControl = nil
                default:
                    throw BotAvatarPathError.unknownCommand(letter)
                }
                readAny = true
                // A move's later pairs are lines, and a later pair of any command keeps the family.
                if Character(effective.uppercased()) == "M" {
                    effective = isRelative ? "l" : "L"
                }
            }

            if !readAny {
                // The letter was followed by another letter, or by the end of the string.
                throw BotAvatarPathError.malformedNumber(String(letter))
            }
            if !placed {
                throw BotAvatarPathError.missingInitialMove
            }
        }

        guard !commands.isEmpty else { throw BotAvatarPathError.empty }
        guard commands.first?.isMove == true else { throw BotAvatarPathError.missingInitialMove }
        return commands
    }

    /// The commands in a canvas `side` points wide, with the view box's origin applied.
    public static func mapped(_ commands: [BotAvatarPathCommand],
                              geometry: BotAvatarGeometry = .shipped,
                              side: Double) -> [BotAvatarPathCommand] {
        func place(_ point: BotAvatarPoint) -> BotAvatarPoint {
            geometry.point(point, inSide: side)
        }
        return commands.map { command in
            switch command {
            case .move(let to): return .move(to: place(to))
            case .line(let to): return .line(to: place(to))
            case .quad(let control, let to): return .quad(control: place(control), to: place(to))
            case .cubic(let c1, let c2, let to):
                return .cubic(control1: place(c1), control2: place(c2), to: place(to))
            case .close: return .close
            }
        }
    }

    /// Points along the path, curves flattened. Used for bounds and for tests.
    ///
    /// Curves are sampled rather than bounded from their control points: a control-point box is
    /// always at least as large as the curve and often visibly larger, which would make a
    /// "does this fit" check meaningless.
    public static func flattenedPoints(_ commands: [BotAvatarPathCommand],
                                       curveSteps: Int = 24) -> [BotAvatarPoint] {
        var points: [BotAvatarPoint] = []
        var current = BotAvatarPoint.zero
        var subpathStart = BotAvatarPoint.zero
        let steps = Swift.max(1, curveSteps)

        for command in commands {
            switch command {
            case .move(let to):
                current = to
                subpathStart = to
                points.append(to)
            case .line(let to):
                current = to
                points.append(to)
            case .quad(let control, let to):
                for index in 1...steps {
                    let t = Double(index) / Double(steps)
                    let mt = 1 - t
                    points.append(BotAvatarPoint(mt * mt * current.x + 2 * mt * t * control.x + t * t * to.x,
                                                 mt * mt * current.y + 2 * mt * t * control.y + t * t * to.y))
                }
                current = to
            case .cubic(let c1, let c2, let to):
                for index in 1...steps {
                    let t = Double(index) / Double(steps)
                    let mt = 1 - t
                    let a = mt * mt * mt
                    let b = 3 * mt * mt * t
                    let c = 3 * mt * t * t
                    let d = t * t * t
                    points.append(BotAvatarPoint(a * current.x + b * c1.x + c * c2.x + d * to.x,
                                                 a * current.y + b * c1.y + c * c2.y + d * to.y))
                }
                current = to
            case .close:
                current = subpathStart
                points.append(subpathStart)
            }
        }
        return points
    }

    /// The box the path's ink occupies, or `nil` for a path with no drawn points.
    public static func bounds(of commands: [BotAvatarPathCommand],
                              curveSteps: Int = 24) -> BotAvatarRect? {
        let points = flattenedPoints(commands, curveSteps: curveSteps)
        guard let first = points.first else { return nil }
        var result = BotAvatarRect(x: first.x, y: first.y, width: 0, height: 0)
        for point in points.dropFirst() {
            result = result.union(BotAvatarRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        return result
    }

    // MARK: - Scanning

    static func isCommandLetter(_ character: Character) -> Bool {
        "MmLlHhVvCcSsQqTtZzAa".contains(character)
    }

    struct Scanner {
        private let characters: [Character]
        private var index = 0

        init(_ characters: [Character]) {
            self.characters = characters
        }

        var isAtEnd: Bool { index >= characters.count }

        func peek() -> Character? {
            index < characters.count ? characters[index] : nil
        }

        mutating func advance() -> Character {
            let character = characters[index]
            index += 1
            return character
        }

        mutating func skipSeparators() {
            while let character = peek(), character == " " || character == "," || character == "\n"
                || character == "\t" || character == "\r" {
                index += 1
            }
        }

        /// True when the next token starts a number, i.e. another repetition of the command.
        mutating func hasNumberAhead() -> Bool {
            skipSeparators()
            guard let character = peek() else { return false }
            return character.isNumber || character == "-" || character == "+" || character == "."
        }

        mutating func number() throws -> Double {
            skipSeparators()
            var text = ""
            if let sign = peek(), sign == "-" || sign == "+" {
                text.append(sign)
                index += 1
            }
            var digits = 0
            while let character = peek(), character.isNumber {
                text.append(character)
                index += 1
                digits += 1
            }
            if peek() == "." {
                text.append(".")
                index += 1
                while let character = peek(), character.isNumber {
                    text.append(character)
                    index += 1
                    digits += 1
                }
            }
            guard digits > 0 else { throw BotAvatarPathError.malformedNumber(text) }
            if let exponent = peek(), exponent == "e" || exponent == "E" {
                var tail = "e"
                index += 1
                if let sign = peek(), sign == "-" || sign == "+" {
                    tail.append(sign)
                    index += 1
                }
                var exponentDigits = 0
                while let character = peek(), character.isNumber {
                    tail.append(character)
                    index += 1
                    exponentDigits += 1
                }
                if exponentDigits > 0 { text += tail }
            }
            guard let value = Double(text), value.isFinite else {
                throw BotAvatarPathError.malformedNumber(text)
            }
            return value
        }

        /// A coordinate pair; `relativeTo` makes both values offsets from the current point.
        mutating func point(relativeTo origin: BotAvatarPoint?) throws -> BotAvatarPoint {
            let x = try number()
            let y = try number()
            guard let origin else { return BotAvatarPoint(x, y) }
            return BotAvatarPoint(origin.x + x, origin.y + y)
        }
    }
}

extension BotAvatarPathCommand {
    var isMove: Bool {
        if case .move = self { return true }
        return false
    }
}
