import Foundation

/// What "open at login" is currently doing, in terms the settings row can draw.
///
/// It is a value rather than a live query so the copy can be tested without the system service, and
/// so no view has to interpret `SMAppService.Status` — that mapping lives in one place in the app.
///
/// The wording carries a promise this app cannot keep, and deliberately does not make it: a login
/// item starts Hermey when the Mac starts. It does **not** wake a sleeping Mac. launchd skips every
/// job while the machine is asleep, and the wake has to come from the hardware — a Wake-on-LAN magic
/// packet on the local network, or a Bonjour sleep proxy answering for a registered service. Neither
/// is something an app can arrange for itself, so the row says what it does and no more. A test pins
/// that sentence so a future edit cannot quietly upgrade it into a wake claim.
public enum LaunchAtLoginStatus: String, Equatable, Sendable, CaseIterable {
    /// The login item is registered and macOS has it enabled.
    case on
    /// Not registered, or the owner turned it off.
    case off
    /// Registered, but macOS is holding it until the owner allows it in System Settings.
    case needsApproval
    /// This build could not register a login item at all.
    case unavailable

    /// Whether the row's switch draws as on. Only `.on` is on: an entry waiting for approval is not
    /// running at login yet, and drawing it as on would be the app telling the owner something the
    /// system is not doing.
    public var toggleIsOn: Bool { self == .on }

    /// Whether to offer a button that opens System Settings → Login Items.
    public var offersApproval: Bool { self == .needsApproval }

    public var detail: String {
        switch self {
        case .on:
            return "Hermey starts when you log in, so computer use is reachable as soon as the Mac is awake. This does not wake a sleeping Mac."
        case .off:
            return "Hermey does not start by itself. After a restart, computer use stays unavailable until you open the app."
        case .needsApproval:
            return "Allowed here, but macOS is holding it: turn Hermey on under System Settings → General → Login Items."
        case .unavailable:
            return "macOS did not accept a login item for this build, so Hermey will not start by itself."
        }
    }
}
