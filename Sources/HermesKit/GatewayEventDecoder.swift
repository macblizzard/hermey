import Foundation

// MARK: - JSON conveniences

extension JSONValue {
    /// A number whatever the encoder chose. `started_at` and `timestamp` arrive as floats on one
    /// build and integers on another, and neither is worth a failed decode.
    var numberValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
}

extension RPCID {
    /// Ids the gateway mints are strings (`srq-<12 hex>`) and ids we mint are integers; a server
    /// request replayed from `open_requests` must round-trip either way.
    init?(json: JSONValue?) {
        guard let json else { return nil }
        switch json {
        case .string(let s): self = .string(s)
        case .int(let i): self = .int(i)
        default: return nil
        }
    }
}

enum GatewayJSON {
    /// Best-effort text for a field that may be a string, a number, or a whole object.
    static func text(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .null: return nil
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .array, .object:
            return try? JSONRPCCodec.encodeToString(value)
        }
    }

    static func date(_ value: JSONValue?) -> Date? {
        guard let seconds = value?.numberValue, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Arguments as a human reads them: pretty-printed JSON for a structure, the plain string for
    /// anything scalar. A card's detail pane opens this, so "compact one-liner" is not good enough.
    static func prettyText(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case .object, .array:
            guard let compact = try? JSONRPCCodec.encodeToString(value),
                  let data = compact.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                           options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: pretty, encoding: .utf8) else {
                return try? JSONRPCCodec.encodeToString(value)
            }
            return text
        default:
            return text(value)
        }
    }
}

// MARK: - Event envelope

/// Unwraps the gateway's event envelope.
///
/// Every event on the wire is `{"method":"event","params":{"type":<name>,"session_id":<sid>,
/// "payload":<body>,"seq":<n>}}` — **not** `{"method":"message.delta"}`. A client that switches on
/// the notification method never fires a single delta; that is the bug `fixtures/NOTES.md` exists to
/// prevent, and `Fixtures.swift` pins it.
enum GatewayEventDecoder {

    /// `nil` means "an event we do not model yet" and the caller emits `.unknown` rather than
    /// dropping it — a Hermes upgrade must never make the transcript go quiet. An **empty** array
    /// is the different case: a modelled event that carries nothing to show (an empty
    /// `thinking.delta` heartbeat, the `null text` segment boundary), which is not worth an
    /// `.unknown`.
    static func events(type: String, session: SessionID, payload: JSONValue) -> [ClientEvent]? {
        switch type {
        case "message.delta":
            // A null `text` is the reply-segment boundary, not an empty chunk: emitting "" would
            // make a renderer insert a break where the model wrote nothing.
            guard let text = payload["text"]?.stringValue else { return [] }
            return [.messageDelta(session: session, text: text)]

        case "thinking.delta":
            // Measured: `{"text": "..."}` and, repeatedly, `{"text": ""}` as a heartbeat while the
            // model is still deciding. The heartbeat is not content and must not reach a UI that
            // would read an empty chunk as "reasoning finished, clear the bubble".
            guard let text = payload["text"]?.stringValue, !text.isEmpty else { return [] }
            return [.thinkingDelta(session: session, text: text)]

        case "reasoning.delta":
            // The model's actual reasoning stream. `thinking.delta` is *not* it — that channel
            // carries the gateway's own wait notices and spinner text (`agent_callbacks`
            // `_agent_thinking_update`), while reasoning arrives on `reasoning.delta`
            // (`_emit_reasoning_delta`, gated by `display.show_reasoning`, default on). A decoder
            // that only knew `thinking.delta` showed no reasoning at all, on every turn.
            guard let text = payload["text"]?.stringValue, !text.isEmpty else { return [] }
            return [.thinkingDelta(session: session, text: text)]

        case "message.interim":
            // Measured payload: `{text, already_streamed, turn_id?, segment?}`. `already_streamed`
            // means those same words also arrived as `message.delta`, so a client that appends the
            // text as a row must clear the live bubble it was streaming into, or the sentence
            // appears twice. A re-sent seal of the same segment carries the same key and is not a
            // new bubble.
            guard let text = payload["text"]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            let turn = payload["turn_id"]?.stringValue ?? ""
            let segment = payload["segment"].flatMap { $0.stringValue ?? ($0.intValue.map(String.init)) } ?? ""
            return [.interimMessage(session: session,
                                    text: text,
                                    alreadyStreamed: payload["already_streamed"]?.boolValue ?? false,
                                    key: "\(turn)#\(segment)")]

        case "message.complete":
            // Usage rides on the completion, and the compaction decision is made on it, so the
            // count is published *before* the completion the app reacts to.
            var events: [ClientEvent] = []
            if let usage = usage(payload) {
                events.append(.contextUsage(session: session,
                                            used: usage.used,
                                            max: usage.max,
                                            percent: usage.percent))
            }
            events.append(.messageComplete(session: session, text: GatewayJSON.text(payload["text"]) ?? ""))
            return events

        case "tool.start":
            guard let callID = payload["tool_id"]?.stringValue ?? payload["tool_call_id"]?.stringValue
            else { return [] }
            return [.toolStart(session: session,
                               name: payload["name"]?.stringValue ?? "",
                               callID: callID,
                               input: toolInput(payload))]

        case "tool.progress":
            guard let callID = payload["tool_id"]?.stringValue else { return [] }
            return [.toolProgress(session: session, callID: callID, text: progressText(payload))]

        case "tool.complete":
            guard let callID = payload["tool_id"]?.stringValue else { return [] }
            return [.toolComplete(session: session,
                                  name: payload["name"]?.stringValue,
                                  callID: callID,
                                  output: toolOutput(payload),
                                  ok: succeeded(payload),
                                  durationMS: payload["duration_s"]?.numberValue.map { Int(($0 * 1000).rounded()) })]

        // The backend has no single "session changed" event; these are the three that move a row in
        // the rail, and one repaint signal covers all of them.
        case "session.info", "session.title", "session.reclaimed", "session.control.update":
            return [.sessionUpdated(session)]

        case "reaction.updated":
            // A host-originated event, not the engine's: `reactions.rs` broadcasts it when any
            // device sets or clears an emoji. `payload.session` names the conversation because the
            // frame is also read by sockets attached to another one; a frame without a placeable
            // message is dropped rather than applied to whatever is open.
            guard let message = payload["message"]?.stringValue,
                  ReactionKey.isValidMessage(message) else { return [] }
            let bot = payload["bot"]?.stringValue ?? ""
            // The conversation the frame is about. Empty or absent means "the one this socket is
            // attached to", which is what `attributedSession` already decided.
            let target = payload["session"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? session
            // `null` for a removal, a string for a set; either way `stringValue` is nil when it is
            // not a string, which is the removal case.
            let emoji = payload["emoji"]?.stringValue
            return [.reactionUpdated(bot: bot,
                                     session: target,
                                     message: message,
                                     emoji: emoji,
                                     by: payload["by"]?.stringValue ?? "")]

        case "error":
            // The frame's session travels with the error. One socket is shared by every conversation
            // the app opens — including the bots it opens in the background — so a message without
            // the session it is about cannot be placed, and the app would paint one bot's failure
            // over another bot's transcript. An empty string is the honest "the frame named none".
            return [.error(session: session,
                           code: payload["code"]?.intValue.map { Int($0) },
                           message: payload["message"]?.stringValue ?? "unknown gateway error")]

        default:
            return nil
        }
    }

    /// The first event of a type, for callers that model at most one (`gateway.ready`, tests).
    static func event(type: String, session: SessionID, payload: JSONValue) -> ClientEvent? {
        events(type: type, session: session, payload: payload)?.first
    }

    /// What the tool was called with, as the one line a card can show.
    ///
    /// `tool.start` carries `args` (an object on most tools), `args_text` (the raw call text when
    /// the host has already serialised it), and `context`/`preview` for tools whose argument is a
    /// path or a snippet. Preferring `args_text` avoids re-serialising a body the host already
    /// formatted; the rest keep the row from being empty.
    private static func toolInput(_ payload: JSONValue) -> String {
        if let text = payload["args_text"]?.stringValue, !text.isEmpty { return text }
        if let args = payload["args"], args != .null, let text = GatewayJSON.text(args) { return text }
        if let context = payload["context"]?.stringValue, !context.isEmpty { return context }
        return payload["preview"]?.stringValue ?? ""
    }

    /// What the tool produced, resolved in the order the wire actually populates.
    ///
    /// Measured: `result_text` is what a tool writes for a human and is usually present; `result`
    /// is the structured payload (stringified here so a JSON-only result still renders instead of
    /// blank); `summary` is the fallback for tools that only describe themselves. Reading
    /// `result` first — or a key that is never sent — is why every finished card said "No output."
    private static func toolOutput(_ payload: JSONValue) -> String? {
        if let text = payload["result_text"]?.stringValue, !text.isEmpty { return text }
        if let result = payload["result"], result != .null,
           let text = GatewayJSON.text(result), !text.isEmpty { return text }
        if let summary = payload["summary"]?.stringValue, !summary.isEmpty { return summary }
        return nil
    }

    /// `usage` on `message.complete`. `context_max` is what makes the count meaningful, so a body
    /// without it is reported as no usage rather than as "0 of 0".
    private static func usage(_ payload: JSONValue) -> (used: Int, max: Int, percent: Double?)? {
        guard let usage = payload["usage"]?.objectValue,
              let used = usage["context_used"]?.intValue else { return nil }
        return (used: Int(used),
                max: Int(usage["context_max"]?.intValue ?? 0),
                percent: usage["context_percent"]?.numberValue)
    }

    private static func progressText(_ payload: JSONValue) -> String {
        if let message = payload["message"]?.stringValue, !message.isEmpty { return message }
        if let percent = payload["percent"]?.intValue { return "\(percent)%" }
        let progress = payload["progress"]?.numberValue ?? 0
        if let total = payload["total"]?.numberValue, total > 0 {
            return String(format: "%.0f/%.0f", progress, total)
        }
        return String(format: "%.0f", progress)
    }

    /// The wire carries no explicit `ok`: a failed tool reports itself inside `result`. Infer it,
    /// and default to success so an unrecognised shape never paints a good call as failed.
    private static func succeeded(_ payload: JSONValue) -> Bool {
        guard let result = payload["result"]?.objectValue else { return true }
        if let success = result["success"]?.boolValue { return success }
        if let ok = result["ok"]?.boolValue { return ok }
        if result["is_error"]?.boolValue == true { return false }
        if let error = result["error"], error != .null,
           let text = GatewayJSON.text(error), !text.isEmpty { return false }
        return true
    }
}

// MARK: - Result payloads

/// Decoding of result *bodies*. Kept out of `GatewayClient` so the client file is only about
/// sequencing — correlation, timeouts, handshake, reconnect.
enum GatewayPayloadDecoder {

    struct Resume {
        let resume: SessionResume
        let storedID: SessionID
        let runtimeID: SessionID
    }

    static func sessionResume(_ result: JSONValue?, requestedID: SessionID) throws -> Resume {
        guard let result, result.objectValue != nil else {
            throw GatewayError.malformedResponse(method: "session.resume")
        }
        // `session_id` in the reply is the RUNTIME id (what every session-scoped call needs);
        // `stored_session_id` is the durable key, and the only thing a later resume accepts.
        let runtimeID = result["session_id"]?.stringValue ?? requestedID
        let storedID = result["stored_session_id"]?.stringValue ?? requestedID
        // A paged resume names the offset of its first row and how many rows exist in total, so
        // "load earlier" can continue exactly where this page starts. Absent (an older bridge or a
        // short conversation) means the page is the whole transcript.
        let history = result["history"]?.objectValue
        let cursor = history?["cursor"]?.intValue.map(Int.init)
        let total = history?["total"]?.intValue ?? result["message_count"]?.intValue ?? 0
        let resume = SessionResume(id: runtimeID,
                                   entries: transcript(result["messages"]?.arrayValue ?? [],
                                                       baseOffset: cursor ?? 0),
                                   inflight: inflight(result["inflight"]),
                                   openRequests: (result["open_requests"]?.arrayValue ?? []).compactMap(serverRequest),
                                   earlierCursor: cursor,
                                   historyTotal: Int(total),
                                   storedSessionID: storedID)
        return Resume(resume: resume, storedID: storedID, runtimeID: runtimeID)
    }

    static func inflight(_ value: JSONValue?) -> InflightTurn? {
        guard let value, let object = value.objectValue else { return nil }
        let assistant = object["assistant"]?.stringValue ?? ""
        let user = object["user"]?.stringValue ?? ""
        if assistant.isEmpty && user.isEmpty { return nil }
        return InflightTurn(userText: user, assistantText: assistant, streaming: object["streaming"]?.boolValue ?? false)
    }

    static func serverRequest(_ value: JSONValue) -> ServerRequest? {
        guard let id = RPCID(json: value["id"]), let method = value["method"]?.stringValue else { return nil }
        return ServerRequest(id: id, method: method, params: value["params"] ?? .null)
    }

    /// - Parameter baseOffset: the page's position in the host's transcript. Rows without a durable
    ///   id fall back to a positional one, and two pages of the same conversation would otherwise
    ///   both start at `user-0` — the same identity for two different messages, which makes a
    ///   prepended page fight the list it is joining.
    /// Host notifications about background processes are operational noise in a bot conversation:
    /// they carry command lines and hundreds of lines of poll output, hide the actual messages and
    /// made scrolling expensive. Recognition is narrow — only the runtime's exact banner prefix —
    /// so a person typing about a process still gets their message.
    public static func isProcessNotice(_ text: String) -> Bool {
        text.hasPrefix("[IMPORTANT: Background process ")
    }

    static func transcript(_ messages: [JSONValue], baseOffset: Int = 0) -> [TranscriptEntry] {
        messages.enumerated().compactMap { index, message in
            let rowID = message["row_id"]?.intValue
            let role = TranscriptEntry.Role(rawValue: message["role"]?.stringValue ?? "") ?? .system
            // Row ids are the durable identity a rewind targets and the UI diffs against; without
            // one, a tool call id is stable across reloads, and a positional id is the last resort.
            let id: String
            if let rowID {
                id = "r\(rowID)"
            } else if let callID = message["tool_call_id"]?.stringValue {
                id = "t\(callID)"
            } else {
                id = "\(role.rawValue)-\(baseOffset + index)"
            }
            let text = GatewayJSON.text(message["text"]) ?? GatewayJSON.text(message["content"]) ?? ""
            if Self.isProcessNotice(text) { return nil }
            return TranscriptEntry(id: id,
                                   rowID: rowID,
                                   role: role,
                                   text: text,
                                   at: GatewayJSON.date(message["timestamp"]),
                                   tool: role == .tool ? toolDetail(message) : nil)
        }
    }

    /// A projected tool row, read from the fields it actually carries.
    ///
    /// Measured shape (`session_history._HISTORY_ROLES` branch for `role == "tool"`):
    /// `{"role":"tool","name":"terminal","context":"uptime","args":{…},"labels":[…],
    /// "tool_call_id":"…","timestamp":…}` — and `content`, the result, **only** for
    /// `write_file`/`patch`/`skill_manage`. `text` is absent, so the old text-only decode drew a
    /// blank "Tool" card for every call in history.
    static func toolDetail(_ message: JSONValue) -> TranscriptEntry.ToolDetail? {
        let name = (message["name"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let context = message["context"]?.stringValue.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let args = message["args"].flatMap(GatewayJSON.prettyText)
        let content = GatewayJSON.text(message["content"])
        let labels = message["labels"]?.arrayValue?.compactMap { label -> String? in
            // `as_payload()` is `{text:, kind:}` on some builds and a bare string on others.
            if let text = label["text"]?.stringValue { return text }
            return label.stringValue
        } ?? []
        guard !name.isEmpty || context != nil || args != nil || content != nil else { return nil }
        return TranscriptEntry.ToolDetail(name: name,
                                          context: context,
                                          args: args,
                                          content: content,
                                          labels: labels)
    }

    /// `profiles.list` — the bot directory.
    ///
    /// Measured body: `{"profiles":[{"name":"default"}, …], "bot_mode_protocol":…, "install_id":…}`.
    /// Only the names are contractual, so an entry may also be a bare string or name the field
    /// `profile`; anything else is ignored rather than failing the whole list, and a body without
    /// a `profiles` array is a malformed reply (a silent `[]` would read as "no bots on this host").
    static func bots(_ result: JSONValue?) throws -> [Bot] {
        guard let rows = result?["profiles"]?.arrayValue else {
            throw GatewayError.malformedResponse(method: "profiles.list")
        }
        var seen = Set<String>()
        var bots: [Bot] = []
        for row in rows {
            guard let bot = bot(row), seen.insert(bot.id).inserted else { continue }
            bots.append(bot)
        }
        return bots
    }

    /// `profiles.list` with `include_sessions` — which conversation is this bot's canonical Bot Chat.
    ///
    /// Contract (`tui_gateway/contracts/profiles_vault_complete_foreign_subagents.py`):
    /// `canonical_session` is `{id, resolved_id, title, …}`, and `resolved_id` is the **live
    /// compression tip**. That is the id to hand `session.resume`: with rotation compaction the
    /// registry title can sit on a row whose successor is the one that is live, so resuming `id`
    /// opens a conversation that stopped moving. `id` is the fallback for a host that predates
    /// `resolved_id`.
    ///
    /// A body without a `profiles` array is malformed, exactly as for `bots`. A row with no
    /// `canonical_session` (or `null`) means "this bot has no Bot Chat yet" — the caller mints one.
    static func canonicalBotChatID(_ result: JSONValue?, profile: String?) throws -> String? {
        guard let rows = result?["profiles"]?.arrayValue else {
            throw GatewayError.malformedResponse(method: "profiles.list")
        }
        let objects: [[String: JSONValue]] = rows.compactMap { value in
            if case .object(let object) = value { return object }
            return nil
        }
        let row: [String: JSONValue]?
        if let profile, !profile.isEmpty {
            row = objects.first { profileName($0) == profile }
        } else {
            row = objects.first
        }
        // A profile this connection does not serve is not listed at all: "no row" and "no Bot Chat"
        // both mean nothing to resume here.
        guard let row, let session = row["canonical_session"],
              case .object(let canonical) = session
        else { return nil }
        for key in ["resolved_id", "id"] {
            if let id = Bot.trimmed(canonical[key]?.stringValue ?? "") { return id }
        }
        return nil
    }

    static func bot(_ value: JSONValue) -> Bot? {
        switch value {
        case .string(let name):
            guard let name = Bot.trimmed(name) else { return nil }
            return Bot(id: name)
        case .object(let object):
            guard let name = profileName(object) else { return nil }
            // A display label is a nicety: the profile name is what the switcher falls back to.
            let display = object["display_name"]?.stringValue ?? object["label"]?.stringValue
            return Bot(id: name, name: name, displayName: display,
                       description: object["description"]?.stringValue)
        default:
            return nil
        }
    }

    private static func profileName(_ object: [String: JSONValue]) -> String? {
        for key in ["name", "profile", "id", "slug"] {
            if let name = Bot.trimmed(object[key]?.stringValue) { return name }
        }
        return nil
    }

    static func sessionSummaries(_ result: JSONValue?) throws -> [SessionSummary] {
        guard let rows = result?["sessions"]?.arrayValue else {
            throw GatewayError.malformedResponse(method: "session.list")
        }
        return rows.compactMap { row in
            guard let id = row["id"]?.stringValue else { return nil }
            // The listing row carries `started_at` and no last-active field, so that is the only
            // timestamp there is; `updatedAt` is where the rail sorts it.
            return SessionSummary(id: id,
                                  title: row["title"]?.stringValue ?? "",
                                  updatedAt: GatewayJSON.date(row["started_at"]),
                                  preview: row["preview"]?.stringValue,
                                  running: row["running"]?.boolValue ?? false,
                                  messageCount: row["message_count"]?.intValue.map(Int.init) ?? 0)
        }
    }

    /// The canonical row out of `session.list {title: "Bot Chat"}` — and the count the ceiling reads.
    ///
    /// `live_message_count` first: it is the host's display count, the same grouping a transcript
    /// read paints, so it cannot lag the rows an open would show. `message_count` is the fallback
    /// for a host that predates the field, and it is knowingly smaller (compaction retires rows from
    /// that column while they stay in the transcript), so a roll on this host can come late — never
    /// early, which is the only direction that loses nothing.
    static func botChatRow(_ result: JSONValue?) -> BotChatRow? {
        guard let row = result?["sessions"]?.arrayValue?.first?.objectValue,
              let id = row["id"]?.stringValue, !id.isEmpty else { return nil }
        let live = row["live_message_count"]?.intValue.map(Int.init)
        let stored = row["message_count"]?.intValue.map(Int.init)
        guard let count = live ?? stored else { return nil }
        return BotChatRow(id: id, count: count)
    }

    /// One older page: rows, the offset its first row sits at, and the conversation's row count.
    static func historyPage(_ result: JSONValue?) throws -> HistoryPage {
        guard let result, let messages = result["messages"]?.arrayValue else {
            throw GatewayError.malformedResponse(method: "session.history")
        }
        let cursor = result["cursor"]?.intValue.map(Int.init)
        let entries = transcript(messages, baseOffset: cursor ?? 0)
        return HistoryPage(entries: entries, cursor: cursor,
                           total: Int(result["total"]?.intValue ?? 0))
    }

    static func history(_ result: JSONValue?, limit: Int) throws -> [TranscriptEntry] {
        guard let messages = result?["messages"]?.arrayValue else {
            throw GatewayError.malformedResponse(method: "session.history")
        }
        let entries = transcript(messages)
        return limit > 0 ? Array(entries.suffix(limit)) : entries
    }

    /// The **runtime** ids `session.active_list` reports (`sessions[].id`).
    ///
    /// The row also carries `session_key`, the stored id. The sweep needs the runtime one: that is
    /// what a resume answers with and what `session.close` takes, and comparing a stored id against
    /// this set would never match (the two namespaces look alike and are not interchangeable).
    static func liveSessionIDs(_ result: JSONValue?) -> Set<SessionID> {
        Set((result?["sessions"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
    }

    static func modelOptions(_ result: JSONValue?) throws -> [ModelOption] {
        guard let providers = result?["providers"]?.arrayValue else {
            throw GatewayError.malformedResponse(method: "model.options")
        }
        var options: [ModelOption] = []
        for provider in providers {
            guard let slug = provider["slug"]?.stringValue else { continue }
            for model in provider["models"]?.arrayValue ?? [] {
                guard let name = model.stringValue, !name.isEmpty else { continue }
                options.append(ModelOption(id: name, provider: slug, label: name))
            }
        }
        return options
    }

    /// `model.options`, with the host's own answer to "what is running".
    ///
    /// The top-level `model`/`provider` pair is authoritative (measured: `deepseek-v4.1-flash` on
    /// `opencode-go`), while `providers[0].models[0]` is merely the first entry of a menu — reading
    /// that is what labelled the model chip `anthropic/claude-fable…` on a host running DeepSeek.
    /// When the host omits the pair the catalogue is still useful, so the options survive and
    /// `current` stays nil rather than being guessed.
    static func modelCatalog(_ result: JSONValue?) throws -> ModelCatalog {
        let options = try modelOptions(result)
        guard let model = result?["model"]?.stringValue, !model.isEmpty else {
            return ModelCatalog(current: nil, options: options)
        }
        let provider = result?["provider"]?.stringValue
            ?? options.first { $0.id == model }?.provider
            ?? ""
        return ModelCatalog(current: ModelOption(id: model, provider: provider, label: model),
                            options: options)
    }

    struct EventReplay {
        let events: [JSONValue]
        let latestSeq: Int
        let truncated: Bool
        let epoch: String
    }

    static func eventReplay(_ result: JSONValue?) throws -> EventReplay {
        guard let result, result.objectValue != nil else {
            throw GatewayError.malformedResponse(method: "session.events.since")
        }
        return EventReplay(events: result["events"]?.arrayValue ?? [],
                           latestSeq: Int(result["latest_seq"]?.intValue ?? 0),
                           truncated: result["truncated"]?.boolValue ?? false,
                           epoch: result["epoch"]?.stringValue ?? "")
    }
}
