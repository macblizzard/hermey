import Foundation

// MARK: - The host's canonical Bot Chat

/// Which conversation *is* this bot, as the **host** answers it.
///
/// Before this file, "this bot's conversation" was a Hermey-only idea: one id kept in the bridge's
/// `bot_sessions` row plus a per-device `UserDefaults` cache. That made the phone and the Mac agree
/// with each other and with nothing else. Hermes itself already has an answer — a session whose
/// title is exactly `Bot Chat`, created hidden, resolved by name on every open and shared by
/// Desktop, the TUI, `hermes -p <bot> chat`, cron `bot-chat` delivery and `message_agent` between
/// bots. Two identities cannot both be "the bot's chat": whichever one Hermey opened was invisible
/// to everything else on the host, and everything the host wrote (a routine's report, another bot's
/// DM) landed in a conversation Hermey never showed.
///
/// So the host's row becomes the authority and the bridge pointer demotes to a cache:
///
/// * the host has a canonical chat → open **that** id (its live compression tip, see below);
/// * the host has none, but this bot already has a Hermey conversation → **adopt** it: open it and
///   give it the canonical name, so the history the user already has becomes the shared chat
///   instead of being stranded behind a fresh empty one;
/// * neither → mint the canonical chat the way Desktop does (`title` + `hidden`, so the registry
///   lookup finds it and the sidebar does not list a second copy).
///
/// Nothing here performs I/O: it is the decision, so a test can pin it without a socket, a bridge or
/// a device. `AppModel.endlessSession(for:)` carries it out.
public enum CanonicalBotChat {

    /// The registry key. Bot Mode resolves the canonical chat by **exact** title
    /// (`hermes_state.get_session_by_title`), so this string is an identity, not a label: a single
    /// character off and `message_agent`, cron delivery and the official app stop finding the chat.
    public static let title = "Bot Chat"

    /// What the host said when asked which conversation this bot has.
    public enum HostState: Equatable, Sendable {
        /// A session titled exactly `Bot Chat` exists. The id is its **live tip**: with rotation
        /// compaction the title can live on a row whose meaning moved to a descendant, and the
        /// host's `canonical_session.resolved_id` already follows that chain.
        case canonical(SessionID)
        /// The host answered, and this bot has no canonical chat yet.
        case absent
        /// The host could not be asked (socket down, old gateway without `profiles.list`
        /// session fields, a refused read). Not `.absent`: "I could not see it" and "it is not
        /// there" justify different actions.
        case unavailable
    }

    /// What to do when opening a bot.
    public struct Plan: Equatable, Sendable {
        public enum Step: Equatable, Sendable {
            /// Resume the host's canonical chat.
            case resume(SessionID)
            /// Resume a pre-canonical conversation, then name it `Bot Chat`.
            case adopt(SessionID)
            /// Mint the canonical chat.
            case create
        }

        public let step: Step
        /// Whether the id this open lands on should be written to the bridge's pointer as well.
        ///
        /// It stays useful as a cache: the bot list's previews and unread counts are read from the
        /// bridge, and an older build of this app (or a host whose `profiles.list` cannot answer)
        /// still opens the right conversation from it. It is no longer the authority.
        public let publishCache: Bool

        public init(step: Step, publishCache: Bool) {
            self.step = step
            self.publishCache = publishCache
        }

        public var resumedID: SessionID? {
            switch step {
            case .resume(let id), .adopt(let id): return id
            case .create: return nil
            }
        }
    }

    /// The decision.
    ///
    /// - Parameters:
    ///   - host: what the host answered (see `HostState`).
    ///   - legacy: the bridge pointer, when the bridge could be read.
    ///   - local: this device's cached id.
    public static func plan(host: HostState, legacy: String?, local: String?) -> Plan {
        switch host {
        case .canonical(let raw):
            guard let id = usableID(raw) else {
                // A value that cannot be resumed is not a reason to fail the open: treat the read as
                // "nothing useful here" and fall through to the same rules as `.absent`, which will
                // publish whatever this device lands on and so repair the pointer.
                return planWithoutHost(legacy: legacy, local: local)
            }
            // The host's answer wins outright — even over a pointer that disagrees, which is
            // exactly the case where the other device (or Desktop) moved the conversation on.
            return Plan(step: .resume(id), publishCache: true)

        case .absent:
            return planWithoutHost(legacy: legacy, local: local)

        case .unavailable:
            // Fail open on the cache, but publish nothing: a value we could not read may exist, and
            // writing over it would strand the other device on a conversation the host does not
            // treat as this bot's. Creating is the one exception — a conversation this device just
            // minted cannot already be the answer, so publishing it only helps.
            if let id = usableID(local) ?? usableID(legacy) {
                return Plan(step: .resume(id), publishCache: false)
            }
            return Plan(step: .create, publishCache: true)
        }
    }

    private static func planWithoutHost(legacy: String?, local: String?) -> Plan {
        // The bridge pointer first, then the local cache: the pointer is at least shared with the
        // other device. Either one is adopted — renamed — rather than replaced, because the user's
        // history is in it.
        if let id = usableID(legacy) ?? usableID(local) {
            return Plan(step: .adopt(id), publishCache: true)
        }
        return Plan(step: .create, publishCache: true)
    }

    /// A stored id this client is willing to hand to `session.resume`.
    ///
    /// Stored keys look like `20261106_165329_293f4b`; a trimmed, non-empty, path-safe token is the
    /// whole contract. Empty values, whitespace, newlines, separators and absurd lengths are "no
    /// id" rather than a resume the host answers with `4007`.
    public static func usableID(_ raw: String?) -> SessionID? {
        EndlessSessionPolicy.storedID(raw)
    }

    /// Whether a failure means "another session already holds this title".
    ///
    /// The host raises `ValueError("Title 'Bot Chat' is already in use by session …")` from
    /// `_resolve_title_conflict`, which the gateway surfaces as an RPC error rather than a code a
    /// client can match on. The message is the only witness available, so it is matched literally —
    /// and the consequence of a false negative is only that the caller tries a plain create.
    public static func isTitleConflict(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(rpc) = error else { return false }
        return rpc.message.lowercased().contains("already in use")
    }

    /// Whether a failure means "this gateway does not know the parameter/method at all" — an older
    /// host, which must degrade to the pre-canonical behaviour instead of blocking the open.
    public static func isUnsupported(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(rpc) = error else { return false }
        return rpc.code == -32601 || rpc.code == 4001 && rpc.message.lowercased().contains("unknown")
    }
}
