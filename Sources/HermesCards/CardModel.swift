import Foundation

/// A decoded `card.v1` document.
///
/// The skill's file is written by a bot, not by this app, so decoding is deliberately forgiving:
/// unknown fields are ignored, a missing optional is simply absent, and an unreadable or invalid
/// document becomes `.unavailable` instead of throwing. A card is an *extra* under a reply — the
/// reply's prose must still show when the card cannot.
public struct Card: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case approval
        case task
        case draftEmail = "draft-email"

        /// Unknown input is not coerced: it fails validation, so the card degrades to
        /// "Card not available" rather than drawing an unexpected layout.
        public init?(wire: String) { self.init(rawValue: wire) }
    }

    public enum StatusState: String, Sendable, Equatable, CaseIterable {
        case pending
        case running
        case done
        case error
        case awaitingApproval = "awaiting-approval"
    }

    public enum ActionStyle: String, Sendable, Equatable {
        case primary
        case danger
    }

    /// One label/value pair, used by both `kv` rows (arrays in the wire format) and `fields`
    /// items (objects in the wire format). One type because the view draws them identically.
    public struct Row: Sendable, Equatable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// The three body block shapes the spec allows. Anything else is skipped, never fatal.
    public enum BodyBlock: Sendable, Equatable {
        case text(String)
        case kv([Row])
        case fields([Row])
    }

    public struct Action: Sendable, Equatable, Identifiable {
        public let label: String
        public let send: String
        public let style: ActionStyle?

        /// Buttons carry no id on the wire. The pair is unique in practice (two buttons with the
        /// same label and the same send are the same button), and stable across re-renders.
        public var id: String { label + "\u{1F}" + send }

        public init(label: String, send: String, style: ActionStyle? = nil) {
            self.label = label
            self.send = send
            self.style = style
        }
    }

    public struct Status: Sendable, Equatable {
        public let state: StatusState
        /// The chip's text override. P1's approval layout hides the chip; kept for P3.
        public let label: String?

        public init(state: StatusState, label: String? = nil) {
            self.state = state
            self.label = label
        }
    }

    public struct Resolved: Sendable, Equatable {
        /// The chosen action: normally its `label`, but the skill also accepts its `send` text.
        public let action: String
        public let at: String?

        public init(action: String, at: String? = nil) {
            self.action = action
            self.at = at
        }
    }

    /// What a button is, once the card is resolved: tappable, ticked, or merely locked.
    public enum ActionState: Sendable, Equatable {
        case available
        case chosen
        case locked
    }

    public let schema: String
    public let kind: Kind
    public let title: String
    public let status: Status
    public let body: [BodyBlock]
    public let actions: [Action]
    public let resolved: Resolved?

    public init(schema: String = "card.v1",
                kind: Kind,
                title: String,
                status: Status,
                body: [BodyBlock] = [],
                actions: [Action] = [],
                resolved: Resolved? = nil) {
        self.schema = schema
        self.kind = kind
        self.title = title
        self.status = status
        self.body = body
        self.actions = actions
        self.resolved = resolved
    }

    /// Whether the owner has already chosen.
    public var isResolved: Bool { resolved != nil }

    /// The state of one button. Before `resolved`, every button is available; after it, the
    /// chosen one is ticked and every other one is locked — "answer once" is the whole point.
    public func state(of action: Action) -> ActionState {
        guard let resolved = resolved else { return .available }
        return matches(action, resolved) ? .chosen : .locked
    }

    private func matches(_ action: Action, _ resolved: Resolved) -> Bool {
        let chosen = resolved.action.trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen == action.label || chosen == action.send
    }
}

/// A card document, or the one-line apology a transcript shows when the file is missing or bad.
///
/// `decode` never throws. The engine can answer 404, a bot can write half a file while it is
/// being read, and neither may cost the reply its prose.
public enum CardModel: Sendable, Equatable, Decodable {
    case available(Card)
    case unavailable(String)

    /// The exact text P1 shows for every degradation path.
    public static let unavailableMessage = "Card not available"

    public var card: Card? {
        if case .available(let card) = self { return card }
        return nil
    }

    public var isAvailable: Bool { card != nil }

    public init(data: Data) {
        self = CardModel.decode(data)
    }

    /// The failure path every caller gets: a broken document is an apology, never an error.
    public static func decode(_ data: Data) -> CardModel {
        guard let raw = try? JSONDecoder().decode(RawCard.self, from: data) else {
            return .unavailable(unavailableMessage)
        }
        return raw.validated()
    }

    /// `Decodable` so a card can be decoded anywhere a decoder is already in hand. The initialiser
    /// is non-throwing by contract even though the protocol allows a throw.
    public init(from decoder: Decoder) throws {
        guard let raw = try? RawCard(from: decoder) else {
            self = .unavailable(CardModel.unavailableMessage)
            return
        }
        self = raw.validated()
    }
}

// MARK: - Wire shapes

/// A decoding wrapper that swallows one bad element instead of failing its container. An unknown
/// or malformed body block / action is dropped; the rest of the card still draws.
private struct Failable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) {
        value = try? Value(from: decoder)
    }
}

private struct RawCard: Decodable {
    var schema: String?
    var kind: String?
    var title: String?
    var status: Failable<RawStatus>?
    var body: [Failable<RawBlock>]?
    var actions: [Failable<RawAction>]?
    var resolved: Failable<RawResolved>?
    // `email` is a draft-email field and P1 does not draw that layout. Leaving it undeclared is
    // how Codable ignores it: unknown keys are already tolerated.
}

private struct RawStatus: Decodable {
    var state: String?
    var label: String?
}

private struct RawBlock: Decodable {
    var type: String?
    var text: String?
    var rows: [[String]]?
    var items: [RawRow]?
}

private struct RawRow: Decodable {
    var label: String?
    var value: String?
}

private struct RawAction: Decodable {
    var label: String?
    var send: String?
    var style: String?
}

private struct RawResolved: Decodable {
    var action: String?
    var at: String?
}

// MARK: - Validation

private extension RawCard {
    /// The five rules the spec states, plus the per-element cleanup that keeps a card with one
    /// bad button drawable. Every named violation is `.unavailable`, not a crash.
    func validated() -> CardModel {
        let failure = CardModel.unavailable(CardModel.unavailableMessage)

        guard let schema = schema, schema == "card.v1" else { return failure }
        guard let rawKind = Card.trimmed(kind), let kind = Card.Kind(wire: rawKind) else { return failure }
        guard let title = Card.trimmed(title), !title.isEmpty else { return failure }
        guard let rawStatus = status?.value,
              let rawState = Card.trimmed(rawStatus.state),
              let state = Card.StatusState(rawValue: rawState) else { return failure }

        let rawActions = actions ?? []
        guard rawActions.count <= 3 else { return failure }

        let decodedActions: [Card.Action] = rawActions.compactMap { entry in
            guard let action = entry.value,
                  let label = Card.trimmed(action.label), !label.isEmpty,
                  let send = Card.trimmed(action.send), !send.isEmpty else { return nil }
            // An unknown style is not a broken card: the button simply draws as a neutral one.
            let style = Card.trimmed(action.style).flatMap { Card.ActionStyle(rawValue: $0) }
            return Card.Action(label: label, send: send, style: style)
        }

        let decodedBody = (body ?? []).compactMap { entry in
            Card.bodyBlock(from: entry.value)
        }

        // Read `self.resolved` before naming a local: a `var resolved` here would shadow the
        // decoded field and silently drop every resolution.
        var resolution: Card.Resolved?
        if let rawResolved = self.resolved?.value,
           let chosen = Card.trimmed(rawResolved.action), !chosen.isEmpty {
            resolution = Card.Resolved(action: chosen, at: Card.trimmed(rawResolved.at))
        }

        return .available(Card(schema: schema,
                               kind: kind,
                               title: title,
                               status: Card.Status(state: state, label: Card.trimmed(rawStatus.label)),
                               body: decodedBody,
                               actions: decodedActions,
                               resolved: resolution))
    }
}

private extension Card {
    static func trimmed(_ value: String?) -> String? {
        guard let value = value else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` keeps its whitespace (a paragraph's line breaks are content); `kv` rows are arrays
    /// `[label, value]`; `fields` items are `{label, value}`. Unknown types and empty blocks are
    /// skipped so a stray block cannot stop the rest of the body drawing.
    static func bodyBlock(from raw: RawBlock?) -> BodyBlock? {
        guard let raw = raw, let type = trimmed(raw.type)?.lowercased(), !type.isEmpty else { return nil }

        switch type {
        case "text":
            guard let text = raw.text, !text.isEmpty else { return nil }
            return .text(text)
        case "kv":
            let rows = (raw.rows ?? []).compactMap { pair -> Row? in
                guard pair.count >= 2 else { return nil }
                guard let label = trimmed(pair[0]), !label.isEmpty else { return nil }
                return Row(label: label, value: trimmed(pair[1]) ?? "")
            }
            return rows.isEmpty ? nil : .kv(rows)
        case "fields":
            let rows = (raw.items ?? []).compactMap { item -> Row? in
                guard let label = trimmed(item.label), !label.isEmpty else { return nil }
                return Row(label: label, value: trimmed(item.value) ?? "")
            }
            return rows.isEmpty ? nil : .fields(rows)
        default:
            return nil
        }
    }
}
