import Foundation

// MARK: - Attribute keys
//
// The block layer owns *semantics*, not colours: every attribute below says
// "this run is bold / italic / code / a string token", and each app maps that to
// its own palette. Both apps therefore agree on what a run means even though
// macOS and iOS draw it with different sizes.
//
// Both apps read them with `run.attributes[BoldAttribute.self]`, which is the
// portable Foundation API (the `AttributeScopes` dynamic-member sugar is not
// available in swift-corelibs-foundation, and the block layer has to build and
// test on Linux).

/// Strong emphasis (`**text**`, `__text__`).
public struct BoldAttribute: AttributedStringKey {
    public typealias Value = Bool
    public static let name = "hermesBold"
    public init() {}
}

/// Emphasis (`*text*`, `_text_`).
public struct ItalicAttribute: AttributedStringKey {
    public typealias Value = Bool
    public static let name = "hermesItalic"
    public init() {}
}

/// An inline code span (`` `text` ``). Code *blocks* use `CodeBlockAttribute`
/// instead, so an app never draws a fence's body as one giant inline chip.
public struct InlineCodeAttribute: AttributedStringKey {
    public typealias Value = Bool
    public static let name = "hermesInlineCode"
    public init() {}
}

/// Strikethrough (`~~text~~`). Foundation's `strikethroughStyle` lives in the
/// UIKit/AppKit scopes, so the portable block layer models it itself.
public struct StrikethroughAttribute: AttributedStringKey {
    public typealias Value = Bool
    public static let name = "hermesStrikethrough"
    public init() {}
}

/// Marks a run as part of a fenced code block. The value is the fence's language
/// hint (`"swift"`), or the empty string when the fence had none.
public struct CodeBlockAttribute: AttributedStringKey {
    public typealias Value = String
    public static let name = "hermesCodeBlock"
    public init() {}
}

/// The syntax-highlighting token kind for a run inside a fenced code block.
public struct CodeTokenAttribute: AttributedStringKey {
    public typealias Value = TokenKind
    public static let name = "hermesCodeToken"
    public init() {}
}

// MARK: - Building blocks

extension AttributeContainer {
    /// Bold / italic / code / strikethrough, as one container.
    static func inlineTraits(_ styles: Set<InlineStyle>) -> AttributeContainer {
        var container = AttributeContainer()
        if styles.contains(.strong) { container[BoldAttribute.self] = true }
        if styles.contains(.emphasis) { container[ItalicAttribute.self] = true }
        if styles.contains(.code) { container[InlineCodeAttribute.self] = true }
        if styles.contains(.strikethrough) { container[StrikethroughAttribute.self] = true }
        return container
    }
}

extension AttributedString {
    /// Set an attribute over the whole string without index arithmetic.
    mutating func setAll<T: AttributedStringKey>(_ key: T.Type, to value: T.Value) {
        var container = AttributeContainer()
        container[key] = value
        mergeAttributes(container)
    }
}
