import HermesKit
import SwiftUI

/// One memory document, as plain text the owner can rewrite.
///
/// A memory file is the bot's own list of entries, each separated by the runtime's `\n§\n` delimiter —
/// but this is not a structured editor and it must not pretend to be one. What is on screen is the
/// file, character for character; what Save writes is that text. The two rules the pane keeps are the
/// runtime's:
///
/// * **the budget is shown, not implied** — `4,210 / 6,100 characters`, counted the way
///   `MemoryStore._char_count` counts (entries trimmed and rejoined), so the number here and the number
///   the memory tool reports are one number;
/// * **a save over the budget is refused before it is a request**, with the limit and the overage in the
///   sentence. Nothing is truncated: silently dropping the end of a memory is the one outcome worse than
///   a refusal.
///
/// Monospaced, selectable, no rich text: the file is a text file, and a formatted view would suggest a
/// formatting that will not survive the round trip.
struct BotMemoryEditor: View {
    let botName: String
    let document: BotMemoryDocument
    let read: (String) async throws -> BotMemoryDocument
    let save: (String, String) async throws -> BotMemoryDocument

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var loaded: BotMemoryDocument?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?
    @State private var savedAt: Date?
    @State private var confirming = false
    @FocusState private var editorFocused: Bool

    private var current: BotMemoryDocument { loaded ?? document }
    private var isDirty: Bool { text != (loaded?.text ?? document.text) }

    /// Characters as the runtime counts them, live, so the footer is never a stale number.
    private var used: Int { MemoryBudget.counted(text) }
    private var limit: Int { current.limit }
    private var budgetKnown: Bool { limit > 0 }

    /// Why this text cannot be saved, or `nil` when it can.
    ///
    /// Both limits are the host's as well, and both are checked here first: a save the app knows the
    /// host will refuse is a request that should never be made, and the refusal is more useful as a
    /// sentence beside the editor than as a 409 after a tap.
    private var refusal: String? {
        if budgetKnown, used > limit {
            return MemoryBudget.overBudgetSentence(name: current.name, used: used, limit: limit)
        }
        let bytes = text.utf8.count
        if bytes > MemoryBudget.maxBytes {
            return MemoryBudget.overBytesSentence(name: current.name, bytes: bytes)
        }
        return nil
    }

    private var lineCount: Int { text.components(separatedBy: "\n").count }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .navigationTitle(current.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                        .hermeyFocusQuiet()
                    }
                }
        }
        #else
        content
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if !os(iOS)
            titleBar
            Hairline()
            #endif

            header

            if isLoading {
                HStack(spacing: 8) {
                    SpinningRing(color: Tokens.textMuted, size: 11, lineWidth: 1.4)
                    Text("Reading \(current.name)…")
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let readError = current.error {
                // "The host cannot read it" is a different fact from "it is empty", and it is the one
                // the owner may be able to fix — so it is a sentence, not an empty editor.
                Text(readError)
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            } else {
                editor
            }

            footer
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 560, maxWidth: .infinity,
               minHeight: 420, idealHeight: 560, maxHeight: .infinity)
        #endif
        .background(Tokens.canvas)
        .task { await readFresh() }
        .alert("Save \(current.name)?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            .hermeyFocusQuiet()
            Button("Save") { Task { await write() } }
            .hermeyFocusQuiet()
        } message: {
            Text("\(botName) reads \(current.name) on its next turn. This replaces the whole file on the host.")
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                SectionCaption("MEMORY")
                Text("\(botName) · \(current.name)")
                    .font(TypeScale.font(TypeScale.md, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HermeyButton("Done", kind: .secondary, size: .small) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    /// What this file is, and the one warning that has to be on screen while it is edited.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(current.label.isEmpty ? current.name : current.label)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(lineCount) line\(lineCount == 1 ? "" : "s")")
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(Tokens.textDim)
                    .monospacedDigit()
            }

            Text("Anything written here is visible to \(botName) on every turn — secrets do not belong in it.")
                .font(TypeScale.font(TypeScale.micro))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Nothing yet. What should \(botName) know?")
                    .font(TypeScale.mono(TypeScale.sm))
                    .foregroundStyle(Tokens.textPlaceholder)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }

            // Plain, monospaced and selectable: this is the file's text, not a document with styles.
            TextEditor(text: $text)
                .font(TypeScale.mono(TypeScale.sm))
                .foregroundStyle(Tokens.textPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .textSelection(.enabled)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .focused($editorFocused)
                .disabled(isSaving)
                .accessibilityIdentifier("memoryEditor")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let refusal {
                // The reason, before the button that would have sent it.
                Text(refusal)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error {
                Text(error)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.danger)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Text(budgetKnown ? "\(used.formatted()) / \(limit.formatted()) characters"
                                 : "\(used.formatted()) characters")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(refusal == nil ? Tokens.textDim : Tokens.danger)
                    .monospacedDigit()

                if isSaving {
                    SpinningRing(color: Tokens.textMuted, size: 9, lineWidth: 1.3)
                } else if let savedAt {
                    Text("Saved · \(savedAt.formatted(date: .omitted, time: .shortened))")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                } else if isDirty {
                    Text("unsaved")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                }

                Spacer(minLength: 8)

                HermeyButton("Revert", kind: .secondary, size: .small,
                             isDisabled: isSaving || !isDirty) {
                    revert()
                }
                .accessibilityIdentifier("memoryRevert")

                HermeyButton(isSaving ? "Saving…" : "Save", kind: .primary, size: .small,
                             isDisabled: isSaving || !isDirty || refusal != nil) {
                    confirming = true
                }
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier("memorySave")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Tokens.sheet)
    }

    /// Read the file again as the editor opens: the list this pane was opened from may be a minute old,
    /// and saving its copy back would undo whatever the agent wrote since.
    private func readFresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await read(current.name)
            loaded = fresh
            text = fresh.text
            error = nil
        } catch {
            self.error = MemoryFailure.sentence(error)
        }
    }

    /// Put the file's own text back. Not a re-read: the owner asked to undo what they typed.
    private func revert() {
        text = loaded?.text ?? document.text
        error = nil
        savedAt = nil
    }

    private func write() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await save(current.name, text)
            loaded = saved
            text = saved.text
            savedAt = Date()
            error = nil
        } catch {
            self.error = MemoryFailure.sentence(error)
        }
    }
}
