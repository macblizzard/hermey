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

        /// The state in words — what the chip shows and what VoiceOver reads, so a chip is never
        /// only a colour.
        public var chipText: String {
            switch self {
            case .pending: return "Pending"
            case .running: return "Running"
            case .done: return "Done"
            case .error: return "Error"
            case .awaitingApproval: return "Awaiting approval"
            }
        }
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
        /// The chip's text override: a bot that knows better than the state's own word writes it.
        public let label: String?

        public init(state: StatusState, label: String? = nil) {
            self.state = state
            self.label = label
        }

        /// What the chip reads: the bot's `label` when it wrote one, else the state in words.
        public var chipText: String {
            guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
                return state.chipText
            }
            return label
        }
    }

    /// A `draft-email` card's message: `{to, cc, subject, bodyText}` on the wire, all strings.
    ///
    /// Every field is optional here on purpose. A bot that drafted an email with no `cc` has still
    /// written a draft, and refusing the whole card over one absent recipient would help nobody;
    /// the layout simply leaves that row out.
    public struct Email: Sendable, Equatable {
        public let to: String?
        public let cc: String?
        public let subject: String?
        public let bodyText: String?

        public init(to: String? = nil,
                    cc: String? = nil,
                    subject: String? = nil,
                    bodyText: String? = nil) {
            self.to = to
            self.cc = cc
            self.subject = subject
            self.bodyText = bodyText
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
    /// The message a `draft-email` carries. `nil` for the other kinds, and for a draft-email whose
    /// `email` block was absent or unreadable — that card still draws, under its title.
    public let email: Email?

    public init(schema: String = "card.v1",
                kind: Kind,
                title: String,
                status: Status,
                body: [BodyBlock] = [],
                actions: [Action] = [],
                resolved: Resolved? = nil,
                email: Email? = nil) {
        self.schema = schema
        self.kind = kind
        self.title = title
        self.status = status
        self.body = body
        self.actions = actions
        self.resolved = resolved
        self.email = email
    }

    /// Whether the owner has already chosen.
    public var isResolved: Bool { resolved != nil }

    /// The card's heading: a draft-email draws its subject there (the spec's rule), and every
    /// other kind draws its title.
    public var heading: String {
        guard let subject = Self.trimmed(email?.subject), !subject.isEmpty else { return title }
        return subject
    }

    /// The spec's "a body that is one line under 200 characters, with no line breaks" rule: it
    /// reads as the question under the title rather than as a paragraph of prose.
    ///
    /// Only a body that is *exactly* one text block qualifies — anything else is a layout, and a
    /// layout keeps its own blocks.
    public var leadText: String? {
        guard body.count == 1, case .text(let text) = body[0] else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 200, !trimmed.contains("\n") else { return nil }
        return trimmed
    }

    /// Which action the owner took, spelled as the button they pressed.
    ///
    /// The file may name either the label or the `send` text (the skill accepts both), so the
    /// first matching label wins and an unmatched resolution — a bot that wrote something else —
    /// is shown verbatim rather than hidden.
    public var resolvedLabel: String? {
        guard let resolved = resolved else { return nil }
        return actions.first { matches($0, resolved) }?.label ?? resolved.action
    }

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
    /// `draft-email` only. A card of another kind that carries one is not an error — the field is
    /// read and simply not drawn.
    var email: Failable<RawEmail>?
}

private struct RawEmail: Decodable {
    var to: String?
    var cc: String?
    var subject: String?
    var bodyText: String?
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

        // An `email` block that is not an object is dropped like any other bad element: the card
        // still draws, under its title. `bodyText` keeps its own whitespace — a draft's paragraph
        // breaks are content — but a blank one is no body at all.
        var email: Card.Email?
        if let raw = self.email?.value {
            email = Card.Email(to: Card.trimmed(raw.to),
                               cc: Card.trimmed(raw.cc),
                               subject: Card.trimmed(raw.subject),
                               bodyText: raw.bodyText.flatMap { text -> String? in
                                   text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
                               })
        }

        return .available(Card(schema: schema,
                               kind: kind,
                               title: title,
                               status: Card.Status(state: state, label: Card.trimmed(rawStatus.label)),
                               body: decodedBody,
                               actions: decodedActions,
                               resolved: resolution,
                               email: email))
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
