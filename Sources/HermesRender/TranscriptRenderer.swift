import Foundation

/// Streaming transcript → attributed blocks, with the compile step cached.
///
/// `IncrementalMarkdown.append` reports which block indices changed. This type
/// compiles only those blocks and keeps the `AttributedString` for the rest, so a
/// 200-block conversation gaining one token per frame costs one inline parse, not
/// two hundred — the same invariant the block layer already guarantees, carried
/// through to the text the views actually draw.
public struct TranscriptRenderer: Sendable {
    public private(set) var markdown: IncrementalMarkdown
    public private(set) var metrics: ChatTextMetrics
    /// Number of block compiles performed so far — the cost model, made visible
    /// so tests (and Instruments) can hold it to one-per-changed-block.
    public private(set) var compileCount: Int = 0

    private var cache: [Int: CachedBlock] = [:]

    private struct CachedBlock: Sendable {
        var block: Block
        var text: AttributedString
    }

    public init(metrics: ChatTextMetrics = .macOS) {
        self.markdown = IncrementalMarkdown()
        self.metrics = metrics
    }

    public var blocks: [Block] { markdown.blocks }
    public var blockCount: Int { markdown.blocks.count }

    /// Append a streamed delta; returns the block indices whose text changed.
    @discardableResult
    public mutating func append(_ delta: String) -> [Int] {
        let changed = markdown.append(delta)
        let count = markdown.blocks.count

        if cache.keys.contains(where: { $0 >= count }) {
            cache = cache.filter { $0.key < count }
        }

        for index in changed where index < count {
            let block = markdown.blocks[index]
            if let cached = cache[index], cached.block == block { continue }
            cache[index] = CachedBlock(block: block, text: BlockText.attributed(for: block))
            compileCount += 1
        }
        return changed
    }

    /// The compiled text for a block, if it has been rendered. Every block in
    /// `blocks` is rendered by the time `append` returns.
    public func attributed(at index: Int) -> AttributedString? {
        cache[index]?.text
    }

    /// All rendered blocks in order.
    public var texts: [AttributedString] {
        markdown.blocks.indices.compactMap { cache[$0]?.text }
    }

    /// Replace the whole transcript (e.g. after loading history from disk).
    public mutating func reset(source: String = "") {
        markdown = IncrementalMarkdown()
        cache.removeAll(keepingCapacity: true)
        compileCount = 0
        if !source.isEmpty { append(source) }
    }

    /// Text for one block, compiling and caching it on demand. Used when a view
    /// scrolls to a block that was never on screen; `append` keeps this a hit in
    /// the streaming path.
    public mutating func render(at index: Int) -> AttributedString? {
        guard markdown.blocks.indices.contains(index) else { return nil }
        let block = markdown.blocks[index]
        if let cached = cache[index], cached.block == block { return cached.text }
        let text = BlockText.attributed(for: block)
        cache[index] = CachedBlock(block: block, text: text)
        compileCount += 1
        return text
    }
}
