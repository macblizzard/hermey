import Foundation

/// A bot's effort level and aux/vision model — the two knobs the model sheet owns beyond the model name.
///
/// `effort` is `agent.reasoning_effort` in the profile's own config: `""` means "whatever the provider
/// does by default" and `none` means thinking is switched off entirely (the host stores that one as
/// `false`, not as the string). `vision` is `auxiliary.vision`: the model that looks at pictures when the
/// bot's own model cannot, where the provider `auto` inherits the main model.
public struct BotModelSettings: Equatable, Sendable {
    /// One level the host will accept, with the label the sheet draws. `""` is the provider default.
    public struct EffortOption: Identifiable, Hashable, Sendable {
        public let id: String
        public let label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public let effort: String
    public let efforts: [EffortOption]
    public let visionProvider: String
    public let visionModel: String

    public init(effort: String, efforts: [EffortOption], visionProvider: String, visionModel: String) {
        self.effort = effort
        self.efforts = efforts
        self.visionProvider = visionProvider
        self.visionModel = visionModel
    }

    /// True when the bot inherits the main model for pictures.
    public var visionInherits: Bool { visionProvider == "auto" }

    /// The fallback menu, in the host's own order (`hermes_constants.VALID_REASONING_EFFORTS`), for a
    /// host that answered without a list. A level the host adds later still round-trips: the sheet shows
    /// `effort` as the current value whether or not it is in this list.
    public static let standardEfforts: [EffortOption] = [
        EffortOption(id: "", label: "Provider default"),
        EffortOption(id: "minimal", label: "Minimal"),
        EffortOption(id: "low", label: "Low"),
        EffortOption(id: "medium", label: "Medium"),
        EffortOption(id: "high", label: "High"),
        EffortOption(id: "xhigh", label: "Extra high"),
        EffortOption(id: "max", label: "Max"),
        EffortOption(id: "ultra", label: "Ultra"),
        EffortOption(id: "none", label: "Off"),
    ]

    /// What the sheet calls a level, including one the host named and this client has never heard of.
    public func label(for effort: String) -> String {
        efforts.first { $0.id == effort }?.label
            ?? BotModelSettings.standardEfforts.first { $0.id == effort }?.label
            ?? (effort.isEmpty ? "Provider default" : effort)
    }

    static func decode(_ data: Data) -> BotModelSettings? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let rawEfforts = object["efforts"] as? [Any]
        let efforts: [EffortOption] = (rawEfforts ?? []).compactMap { entry in
            guard let level = entry as? String else { return nil }
            return EffortOption(id: level,
                                label: BotModelSettings.standardEfforts.first { $0.id == level }?.label
                                    ?? (level.isEmpty ? "Provider default" : level))
        }
        let vision = object["vision"] as? [String: Any]
        return BotModelSettings(
            effort: object["effort"] as? String ?? "",
            efforts: efforts.isEmpty ? BotModelSettings.standardEfforts : efforts,
            visionProvider: vision?["provider"] as? String ?? "auto",
            visionModel: vision?["model"] as? String ?? "")
    }
}


/// A pairing invite one device hands another: what `POST /v1/pair/start` answers.
///
/// The URL is what a QR code carries and what the other device pastes — the same `hermes://pair?…`
/// shape `hermey pair` prints, which both apps already parse.
public struct PairingInvite: Equatable, Sendable {
    public let host: String
    public let code: String
    /// Seconds until the code stops being redeemable. Single-use, so a code shown once and scanned
    /// once is the expected life; showing it again mints a new one.
    public let expiresIn: Int

    public init(host: String, code: String, expiresIn: Int) {
        self.host = host
        self.code = code
        self.expiresIn = expiresIn
    }

    /// The link the other device accepts: `hermes://pair?host=<host>&code=<code>`.
    public var url: String {
        var parts = URLComponents(string: "hermes://pair")!
        parts.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "code", value: code),
        ]
        return parts.string ?? "hermes://pair?host=\(host)&code=\(code)"
    }

    static func decode(_ data: Data) -> PairingInvite? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? String, !code.isEmpty else { return nil }
        // `expires_at` is an epoch in seconds; JSON floats decode as NSNumber/Double, never Int.
        let expiresIn = (object["expires_at"] as? Double).map(Int.init) ?? 0
        return PairingInvite(host: object["host"] as? String ?? "",
                             code: code,
                             expiresIn: expiresIn)
    }
}
