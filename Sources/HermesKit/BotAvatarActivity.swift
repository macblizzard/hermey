import Foundation

/// What a bot is doing, said on its face.
///
/// The eight states are the reference's own (`LogoAvatarActivity` in
/// `packages/core/src/logo-avatar-activity.ts`), and they are derived the same way: from explicit
/// run lifecycle, the name of the tool that was *last called*, and the composing/thinking flags —
/// never from a provider's free-text status, which is why the tool sets below are exact.
///
/// **This lives in `HermesKit`, not `HermeyUI`, on purpose.** It is the one vocabulary two layers
/// need: `BotActivityTracker` reduces `ClientEvent`s to it (wire layer, no UI), and `BotAvatarView`
/// draws it (design system, which depends on `HermesKit`). Keeping it here is what lets the tracker
/// return a real activity instead of a parallel enum that the UI would have to translate — a second
/// copy of these rules is exactly how a face starts disagreeing with the reference.
public enum BotAvatarActivity: String, CaseIterable, Hashable, Sendable {
    case idle
    case reading
    case writing
    case thinking
    case computer
    case working
    case waiting
    case error

    /// Tools that read something: a file, a page, the transcript, a skill.
    public static let readingTools: Set<String> = ["read_file", "web_fetch", "read_history", "skill_read"]

    /// Tools that write something down.
    public static let writingTools: Set<String> = ["write_file"]

    /// Tools that drive a machine: a screen, a browser, a shell.
    public static let computerTools: Set<String> = [
        "computer_observe",
        "computer_act",
        "browser_navigate",
        "browser_snapshot",
        "browser_act",
        "user_computer_shell",
        "user_computer_observe",
        "user_computer_act",
        "shell",
        "open_path",
        "launch_app",
    ]

    /// Statuses that mean a run is in flight (`WORKING_RUN_STATUSES`).
    public static let workingStatuses: Set<String> = ["queued", "leased", "running"]

    /// Statuses that mean the run is paused on the user (`WAITING_ON_USER_RUN_STATUSES`).
    public static let waitingStatuses: Set<String> = ["waiting_input", "waiting_takeover"]

    public static func isWorking(status: String?) -> Bool {
        guard let status else { return false }
        return workingStatuses.contains(status)
    }

    public static func isWaitingOnUser(status: String?) -> Bool {
        guard let status else { return false }
        return waitingStatuses.contains(status)
    }

    /// The activity for a run, in the reference's precedence order.
    ///
    /// 1. a background run is `idle` — helper work must not leak into the chat as activity,
    /// 2. `failed` is `error`,
    /// 3. a run paused on the user (an answer, an approval, a takeover) is `waiting`,
    /// 4. anything not in flight — completed, cancelled, unknown, `nil` — is `idle`,
    /// 5. otherwise the **last** tool called picks the pose: computer, then reading, then writing,
    ///    and any other tool is plain `working`,
    /// 6. with no tool call in flight, composing is `writing` and thinking is `thinking`,
    /// 7. and a working run with neither is `working`.
    ///
    /// The order of 5 matters: a shell command that also read a file is `computer`, because the
    /// reference checks the computer set first. And a tool beats composing, because a bot with a
    /// tool call out is no longer just typing.
    public static func from(status: String?,
                            toolNames: [String] = [],
                            composing: Bool = false,
                            thinking: Bool = false,
                            background: Bool = false) -> BotAvatarActivity {
        if background { return .idle }
        if status == "failed" { return .error }
        if isWaitingOnUser(status: status) { return .waiting }
        if !isWorking(status: status) { return .idle }
        if let tool = toolNames.last {
            if computerTools.contains(tool) { return .computer }
            if readingTools.contains(tool) { return .reading }
            if writingTools.contains(tool) { return .writing }
            return .working
        }
        if composing { return .writing }
        if thinking { return .thinking }
        return .working
    }

    /// The working ring, drawn for every state but rest and error — the reference's
    /// `data-working={activity !== "idle" && activity !== "error"}`.
    public var showsWorkingRing: Bool {
        self != .idle && self != .error
    }

    /// Waiting is the one state that is asking the user for something (`logoAvatarNeedsAttention`).
    public var needsAttention: Bool {
        self == .waiting
    }

    /// Whether the body moves at all. Error rests.
    public var isAnimated: Bool {
        self != .error
    }

    /// Spoken as part of an avatar's label, where a caller gives one.
    public var accessibilityDescription: String {
        switch self {
        case .idle: return "idle"
        case .reading: return "reading"
        case .writing: return "writing"
        case .thinking: return "thinking"
        case .computer: return "using the computer"
        case .working: return "working"
        case .waiting: return "waiting for you"
        case .error: return "error"
        }
    }
}
