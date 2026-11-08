import Foundation

/// Validates a single exact profile ID for the bridge's path-based icon API.
public enum BotIconPath {
    public enum Failure: LocalizedError {
        case invalidProfile
        public var errorDescription: String? { "This bot ID cannot be used with the icon service." }
    }
    public static func component(for profile: String) throws -> String {
        guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profile.count <= 256, !profile.contains("/"), profile != ".", profile != ".." else {
            throw Failure.invalidProfile
        }
        return profile
    }
}
