import HermesAppKit
import OpenBotUI
import SwiftUI

/// ⌘K. A filter over the live command list, nothing more.
///
/// The catalogue comes from `WorkspaceStore.commands`, so a verb that cannot run right now
/// (interrupt, with no turn in flight) is listed disabled with its reason instead of
/// vanishing — the palette doubles as a map of what this window can do.
///
/// It is presented as an overlay by `WorkspaceRoot`, not as a sheet: Escape, the backdrop and a
/// second ⌘K all close it (`store.closePalette()`), and it never blocks the chat once gone.
struct CommandPaletteView: View {
    @ObservedObject var store: WorkspaceStore

    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    /// Theme mode lists the catalogue; command mode lists the verbs. Same rows, same keyboard,
    /// same search — "Theme switcher" simply swaps what the panel is a list *of*.
    private var source: [WorkspaceCommand] {
        store.paletteMode == .themes ? store.themeCommands : store.commands
    }

    private var results: [WorkspaceCommand] {
        source.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            Hairline()
            resultsList
            Hairline()
            footer
        }
        .frame(width: 560, height: 440)
        .background(Tokens.sheet)
        .clipShape(RoundedRectangle(cornerRadius: Geometry.radiusPalette, style: .continuous))
        .onAppear { focused = true }
        // As an overlay the view can appear before the window re-focuses; one runloop later is
        // when a text field actually takes first responder.
        .task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            focused = true
        }
        .onChange(of: query) { _ in selected = 0 }
        .onChange(of: results.count) { count in
            if count == 0 { selected = 0 } else { selected = min(selected, count - 1) }
        }
        .onExitCommand { store.closePalette() }
        .preferredColorScheme(.dark)
    }

    // MARK: Search

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(TypeScale.font(Tokens.textMD, weight: .medium))
                .foregroundStyle(Tokens.textDim)

            TextField("",
                      text: $query,
                      prompt: Text("Run a command…").foregroundColor(Tokens.textPlaceholder))
                .textFieldStyle(.plain)
                .font(TypeScale.font(Tokens.textXL))
                .foregroundStyle(Tokens.textPrimary)
                .tint(Tokens.accent)
                .focused($focused)
                .onSubmit { runChosen() }
                // Arrow keys move the highlight instead of the caret: this field is a list
                // filter, and one line of text has nowhere to scroll to.
                .onKeyPress(.upArrow) {
                    move(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    move(1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    store.closePalette()
                    return .handled
                }
                .accessibilityLabel("Search commands")

            Text("esc")
                .font(Tokens.mono)
                .foregroundStyle(Tokens.textDim)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                        .fill(Tokens.control)
                )
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty {
            VStack(spacing: 6) {
                Text("No command matches “\(query)”.")
                    .font(TypeScale.font(Tokens.textMD))
                    .foregroundStyle(Tokens.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.offset) { pair in
                            row(pair.element, at: pair.offset)
                                .id(pair.offset)
                        }
                    }
                    .padding(6)
                }
                // The keyboard walks the list faster than the list scrolls itself: arrowing past
                // the fold used to select a row that was runnable and invisible, so ⏎ fired a
                // command the user could not read. Follow the highlight instead.
                .onChange(of: selected) { _, index in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
    }

    private func row(_ command: WorkspaceCommand, at index: Int) -> some View {
        Button {
            run(command)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: command.systemImage)
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(command.isEnabled ? Tokens.textSecondary : Tokens.textDim)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                            .fill(Tokens.control)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title)
                        .font(TypeScale.font(Tokens.textMD, weight: .medium))
                        .foregroundStyle(command.isEnabled ? Tokens.textPrimary : Tokens.textDim)
                        .lineLimit(1)

                    Text(command.subtitle)
                        .font(TypeScale.font(TypeScale.label))
                        .foregroundStyle(Tokens.textDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                Text(command.group.rawValue.uppercased())
                    .font(TypeScale.font(TypeScale.micro, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Tokens.textDim)

                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(Tokens.mono)
                        .foregroundStyle(Tokens.textDim)
                        .frame(minWidth: 30, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                    .fill(index == selected ? Tokens.controlActive : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(rest: .clear, hover: Tokens.control, radius: Tokens.radiusControl)
        .disabled(!command.isEnabled)
        .accessibilityLabel("\(command.title). \(command.subtitle)")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(results.count == 1 ? "1 command" : "\(results.count) commands")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)

            Spacer(minLength: 0)

            Text("↑↓ choose · ⏎ run · esc closes")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Actions

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let next = selected + delta
        selected = min(max(0, next), results.count - 1)
    }

    /// Return runs the highlighted row; the first runnable one when nothing is highlighted.
    private func runChosen() {
        if results.indices.contains(selected), results[selected].isEnabled {
            run(results[selected])
            return
        }
        guard let first = results.first(where: { $0.isEnabled }) else { return }
        run(first)
    }

    private func run(_ command: WorkspaceCommand) {
        guard command.isEnabled else { return }
        store.closePalette()
        command.run()
    }
}

// MARK: - Previews

private struct CommandPalettePreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        CommandPaletteView(store: store)
            .padding(24)
            .background(Tokens.canvas)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Command palette") {
    CommandPalettePreview()
}
#endif
