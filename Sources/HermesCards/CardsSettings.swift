import Foundation

/// The `cards.enabled` rollback switch.
///
/// Default **on**: a reply that carries a card marker draws the card. Turning it off is the old
/// behaviour — `::card{…}` lines render as plain text — and, like the A2UI switch, it is a
/// user-defaults write rather than a rebuild:
///
///     defaults write dev.hermey.app cards.enabled -bool NO
///
/// The caller is the one that honours "off": `CardMarker` still finds the markers (the parser is
/// not a policy holder), and the transcript renders the untouched prose when this is false.
public enum CardsSettings {
    /// The key the app reads and the `defaults` command writes.
    public static let enabledKey = "cards.enabled"

    /// Whether native cards should draw. An absent key, or a value that is not a bool, is the
    /// default: on.
    public static var isEnabled: Bool {
        get { isEnabled(in: .standard) }
        set { setEnabled(newValue, in: .standard) }
    }

    /// The same answer for an injected store, so a test (or a second suite) never has to touch
    /// the app's real defaults.
    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: enabledKey) as? Bool) ?? true
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: enabledKey)
    }
}
