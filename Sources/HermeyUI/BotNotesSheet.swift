import HermesKit
import SwiftUI

/// The owner's plan for one bot, in that bot's own menu.
///
/// Not the description (`BotModelSettingsScreen` says what a bot *is*, and it is shown in the
/// roster) and not the memory sheet (that is what the *agent* wrote and carries into every turn).
/// This is the owner's scratch pad: the next errand, the thing to pick up next week, the questions
/// to ask when there is time — read by nobody but the next person who opens it.
///
/// It is host state, not device state: one file per bot on the host, so the phone and the Mac open
/// the same text, and deleting the bot deletes the note with it. That is why there is no local
/// cache, no merge and no sync engine here — read on open, write on Save, last write wins.
public struct BotNotesSheet: View {
    public let botName: String
    /// Read the note from the host each time the sheet opens: a note written on the other device a
    /// minute ago must not be drawn as the stale one this device happens to hold.
    public let load: () async throws -> BotNotes
    public let save: (String) async throws -> BotNotes

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var loaded: BotNotes?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?
    @State private var savedAt: Date?
    @FocusState private var editorFocused: Bool

    public init(botName: String,
                load: @escaping () async throws -> BotNotes,
                save: @escaping (String) async throws -> BotNotes) {
        self.botName = botName
        self.load = load
        self.save = save
    }

    private var isDirty: Bool { text != (loaded?.text ?? "") }

    public var body: some View {
        // The Mac's sheet is a panel with its own title bar. The phone's sheets are all navigable
        // screens with an inline title and a Done control in the navigation bar; this one used to use
        // the Mac panel on iOS too, which is why it looked unlike every sheet beside it (reported
        // 2026-11-17).
        #if os(iOS)
        NavigationStack {
            sheetContent
                .navigationTitle("Notes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #else
        sheetContent
        #endif
    }

    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if !os(iOS)
            titleBar
            Hairline()
            #endif

            if isLoading {
                HStack(spacing: 8) {
                    SpinningRing(color: Tokens.textMuted, size: 11, lineWidth: 1.4)
                    Text("Reading the note…")
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loaded, let readError = loaded.error {
                // "The host cannot read it" is a different fact from "it is empty", and it is the
                // one the owner may be able to fix.
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
        .frame(minWidth: 420, idealWidth: 520, maxWidth: .infinity,
               minHeight: 380, idealHeight: 520, maxHeight: .infinity)
        #endif
        .background(Tokens.canvas)
        .task { await read() }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                SectionCaption("NOTES")
                Text(botName)
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

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("What is next with \(botName)? Errands, questions, things to pick up later.")
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(Tokens.textPlaceholder)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(TypeScale.font(TypeScale.md))
                .foregroundStyle(Tokens.textPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .focused($editorFocused)
                .accessibilityIdentifier("botNotesEditor")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(text.count) characters")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .monospacedDigit()

            if let error {
                Text(error)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.danger)
                    .lineLimit(1)
            } else if isSaving {
                SpinningRing(color: Tokens.textMuted, size: 9, lineWidth: 1.3)
            } else if let savedAt {
                Text("Saved · \(savedAt.formatted(date: .omitted, time: .shortened))")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
            } else if !isDirty {
                // Where the note came from, said once: the point of the row is that another device
                // sees the same words.
                Text("Stored on the host — every device reads this same note.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HermeyButton(isSaving ? "Saving…" : "Save",
                          kind: .primary,
                          size: .small,
                          isDisabled: isSaving || !isDirty) {
                Task { await write() }
            }
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Tokens.sheet)
    }

    private func read() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let note = try await load()
            loaded = note
            text = note.text
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func write() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let note = try await save(text)
            loaded = note
            text = note.text
            savedAt = note.updatedAt ?? Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
