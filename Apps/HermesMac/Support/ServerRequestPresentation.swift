import Foundation
import HermesKit

/// What a `ServerRequest` means to a screen.
///
/// The gateway's requests are a small family with no shared schema: `approval` carries
/// `{kind, prompt}`, `clarify` carries a question and maybe choices, `sudo`/`secret` carry a
/// prompt and nothing else. Rather than guess per call site, everything reads through this
/// one projection — and when a field is missing the card falls back to the raw params, so
/// the user always sees exactly what the host asked, never a blank card with a Yes button.
struct ServerRequestPresentation {
    let method: String
    let tool: String
    let command: String
    let rationale: String?
    let scope: String
    let choices: [String]
    let rawJSON: String

    /// Methods this build can answer. Everything else is offered a Decline so the agent is
    /// not left blocked on a request nobody can render (`fixtures/NOTES.md` §2).
    static let answerable: Set<String> = ["approval", "clarify", "sudo", "secret"]

    var isSupported: Bool { ServerRequestPresentation.answerable.contains(method) }

    init(_ request: ServerRequest) {
        let params = request.params
        method = request.method
        rawJSON = params.prettyJSON

        tool = params.firstString("tool", "kind", "name") ?? request.method

        let prompt = params.firstString("prompt", "command", "target", "path", "question", "message")
        command = prompt ?? params.prettyJSON

        rationale = params.firstString("reason", "why", "detail", "description")

        scope = params.firstString("scope") ?? "this session"

        if case .array(let values)? = params["choices"] {
            choices = values.compactMap { value in
                if let text = value.stringValue { return text }
                if case .object = value {
                    return value.firstString("label", "value", "title")
                }
                return nil
            }
        } else {
            choices = []
        }
    }
}

extension JSONValue {
    /// The first present, non-empty string among `keys`, in the order given. Key order is
    /// the protocol's own preference order, not alphabetical: `prompt` before `command`,
    /// because a prompt is prose and a command is not.
    func firstString(_ keys: String...) -> String? {
        for key in keys {
            guard let value = self[key] else { continue }
            if let text = value.stringValue, !text.isEmpty { return text }
        }
        return nil
    }

    /// Deterministic, readable JSON — the fallback a card shows when it cannot name a field.
    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "(unreadable params)"
        }
        return text
    }
}
