import HermesRender
import OpenBotUI
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(renderer.blocks.indices), id: \.self) { index in
                MacBlockView(block: renderer.blocks[index],
                             attributed: renderer.attributed(at: index),
                             metrics: metrics)
            }

            if isStreaming {
                StreamingCaret()
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { synchronise(text) }
        .onChange(of: text) { _, newValue in synchronise(newValue) }
    }

    /// Feed only what is new to the block layer.
    private func synchronise(_ newValue: String) {
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
