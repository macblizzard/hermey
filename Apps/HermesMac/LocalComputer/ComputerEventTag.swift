import Foundation

/// The tag Hermey writes into every synthetic CGEvent it posts.
///
/// A listen-only tap uses it to tell "a bot did this" from "a human just touched the mouse or
/// keyboard": the takeover primitive has to react to the second kind and ignore the first, or a
/// bot's own click would pause the bot.
enum ComputerEventTag {
    static let herm: Int64 = 0x4845524D  // "HERM"
}
