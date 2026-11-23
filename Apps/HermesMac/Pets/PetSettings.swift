import Foundation
import HermesKit

/// Where this Mac keeps its pets: one switch and one position per bot, in this Mac's defaults.
///
/// Local, not synced — which pets are on *this* desk is a property of this desk, not of the bot
/// (design, "Decisions worth stating"). The keys are built in exactly one place because the settings
/// sheet, the controller and the pet's own **Close pet** menu all have to agree about which part of
/// which bot they are writing: three literals is how a toggle starts switching off a pet the
/// controller is not watching.
enum PetSettings {
    /// Posted after any write, carrying `bot` in `userInfo`, so an open settings sheet shows a
    /// toggle that moved because the pet was closed from its own menu.
    static let changedNotification = Notification.Name("pets.changed")
    static let botKey = "bot"

    /// `<prefix><bot>` — the switch. Read by the controller, written by the toggle and by Close pet.
    static let enabledPrefix = "pets.enabled."
    /// `<prefix><bot>` = `"x,y,screenID"`. Read at launch, written on every drag end.
    static let positionPrefix = "pets.position."

    static func enabledKey(for botID: String) -> String { enabledPrefix + botID }
    static func positionKey(for botID: String) -> String { positionPrefix + botID }

    static func isEnabled(_ botID: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey(for: botID))
    }

    /// Writes the switch and tells anyone looking. Returns whether this changed anything.
    @discardableResult
    static func setEnabled(_ enabled: Bool, for botID: String,
                           defaults: UserDefaults = .standard) -> Bool {
        let key = enabledKey(for: botID)
        guard defaults.bool(forKey: key) != enabled else { return false }
        defaults.set(enabled, forKey: key)
        announce(botID, defaults: defaults)
        return true
    }

    static func position(_ botID: String, defaults: UserDefaults = .standard) -> PetPlacement? {
        guard let raw = defaults.string(forKey: positionKey(for: botID)) else { return nil }
        return PetPlacement.decode(raw)
    }

    /// `nil` forgets the position: a pet closed from its own menu comes back centred next time it is
    /// switched on, which is what "close" means for something that was dragged.
    static func setPosition(_ placement: PetPlacement?, for botID: String,
                            defaults: UserDefaults = .standard) {
        let key = positionKey(for: botID)
        guard let placement else {
            guard defaults.object(forKey: key) != nil else { return }
            defaults.removeObject(forKey: key)
            announce(botID, defaults: defaults)
            return
        }
        guard defaults.string(forKey: key) != placement.encoded else { return }
        defaults.set(placement.encoded, forKey: key)
    }

    private static func announce(_ botID: String, defaults: UserDefaults) {
        NotificationCenter.default.post(name: changedNotification,
                                        object: defaults,
                                        userInfo: [botKey: botID])
    }
}
