import Foundation

/// The two switches that decide whether a reply draws natively or as a WebView card.
///
/// Rollback is a user-defaults write, not a rebuild:
///
///     defaults write dev.hermey.app a2ui.surfaces.disabled -bool YES
///
/// With surfaces disabled the app draws `::blocks` boards exactly as it did before A2UI existed,
/// which is what makes the trial reversible in seconds. The server side has its own switch
/// (`plugins.enabled` in the engine config): both have to agree before a reply renders natively,
/// and either one alone is a complete rollback of the drawing path.
public enum A2UISurfaceSettings {
    /// `true` disables native surfaces: the genui `::blocks` path draws instead.
    public static let disabledKey = "a2ui.surfaces.disabled"

    /// Whether a reply carrying an A2UI surface should be drawn natively. Default: yes.
    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: disabledKey) as? Bool != true
    }
}
