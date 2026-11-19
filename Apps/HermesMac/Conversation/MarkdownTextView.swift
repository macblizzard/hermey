import HermesRender
import HermeyUI
import SwiftUI

/// A message body, rendered incrementally.
///
/// The one invariant: when the text grows, only the blocks that changed are recompiled
/// (`TranscriptRenderer.append`), and when the view first appears the whole body is compiled
/// once. That is what keeps a 200-block conversation gaining tokens smooth — and it is the
/// same code path for a finished message and a streaming one, so a streamed answer cannot
/// look different from the same answer reloaded from history.
/// A raw message body drawn as markdown: for screens that hold a string rather than a
/// `TranscriptEntry` — a room's transcript, where the message came from the host's room log.
func markdownMessage(_ text: String) -> AnyView {
    AnyView(MarkdownTextView(text: text))
}

struct MarkdownTextView: View {
    let text: String
    var metrics: ChatTextMetrics = .macOSScaled
    var isStreaming: Bool = false

    @State private var renderer = TranscriptRenderer()
    @State private var renderedSource = ""

    /// Files from the bots' shared store become cards; the bare URL is taken out of the prose so a
    /// message shows the card instead of the link underneath it. Every caller passes a raw message
    /// body, so this one place covers replies, bot-to-bot messages and room history alike.
    ///
    /// These are filled in `init` and refreshed by `synchronise`, never from `body`. They used to be
    /// written by the `cleanText` getter itself — which `body` reads — so drawing a row mutated
    /// state mid-layout. SwiftUI answers that with "Modifying state during view update, this will
    /// cause undefined behavior": 486 warnings a minute at ~15% CPU with the app sitting still, and
    /// a scroll that felt sticky because every row kept invalidating itself while being laid out.
    @State private var cachedSource: String
    @State private var cachedClean: String
    @State private var cachedLinks: [HermesFileLink]

    init(text: String, metrics: ChatTextMetrics = .macOSScaled, isStreaming: Bool = false) {
        self.text = text
        self.metrics = metrics
        self.isStreaming = isStreaming
        // Cheap and pure, so it belongs to the value's creation rather than to a later pass: the
        // first body then draws finished text instead of flashing the raw form.
        _cachedSource = State(initialValue: text)
        _cachedClean = State(initialValue: HermesFileLinks.removingLinks(from: text))
        _cachedLinks = State(initialValue: HermesFileLinks.find(in: text))
    }

    /// Reading never writes. A new text that has not reached `synchronise` yet is cleaned on the spot
    /// — that pass is the only one that pays for it, and it is not persisted.
    private var cleanText: String {
        if cachedSource == text { return cachedClean }
        return HermesFileLinks.removingLinks(from: text)
    }

    private var fileLinks: [HermesFileLink] {
        if cachedSource == text { return cachedLinks }
        return HermesFileLinks.find(in: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(renderer.blocks.indices), id: \.self) { index in
                MacBlockView(block: renderer.blocks[index],
                             attributed: renderer.attributed(at: index),
                             metrics: metrics)
            }

            ForEach(fileLinks) { link in
                HermesFileLinkCard(link: link)
            }

            if isStreaming {
                StreamingCaret()
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { synchronise(cleanText) }
        .onChange(of: cleanText) { _, newValue in synchronise(newValue) }
    }

    /// Feed only what is new to the block layer, and remember the parse of the raw text so the next
    /// body does not repeat it. Called from `onAppear`/`onChange`, which is a legal place to write
    /// state; `body` only reads.
    private func synchronise(_ newValue: String) {
        if cachedSource != text {
            cachedSource = text
            cachedClean = newValue
            cachedLinks = HermesFileLinks.find(in: text)
        }
        guard newValue != renderedSource else { return }
        if newValue.hasPrefix(renderedSource) {
            let delta = String(newValue.dropFirst(renderedSource.count))
            if !delta.isEmpty {
                renderer.append(delta)
            }
        } else {
            // A rewind or a resume replaced the text: start the blocks over rather than
            // appending onto a prefix that no longer exists.
            renderer.reset(source: newValue)
        }
        renderedSource = newValue
    }
}

/// The caret at the end of a live turn. Stops moving under Reduce Motion and carries no
/// meaning on its own — the "running" chip in the header says the same thing in words.
struct StreamingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Tokens.accent)
            .frame(width: 7, height: 14)
            .opacity(bright ? 0.9 : 0.3)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    bright = false
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

private struct MarkdownTextViewPreview: View {
    private let sample = """
    Snapshotting the **vault** first, then I'll diff the `docs/` tree.

    **Plan**

    1. `rsync` the vault to `~/backup/vault`
    2. Diff `docs/` against the backup
    3. Report only files that changed

    > Nothing is deleted until the diff is reviewed.

    ```sh
    rsync -a --delete ~/vault/ ~/backup/vault/
    ```
    """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MarkdownTextView(text: sample)
                MarkdownTextView(text: "Backup is in place — 1,204 files, no errors.", isStreaming: true)
            }
            .padding(24)
            .frame(width: Geometry.conversationMeasure, alignment: .leading)
        }
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Markdown view") {
    MarkdownTextViewPreview()
}
#endif
