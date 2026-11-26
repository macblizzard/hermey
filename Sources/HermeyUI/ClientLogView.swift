import Combine
import SwiftUI
import HermesKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A copy that actually happened, so the sheet can say how much of the log left it rather than
/// claiming a success it cannot measure. The scope is `ClientLogCopyScope` (HermesKit), which owns
/// both the list a scope copies and the words it is offered in — a label built here and a list built
/// there is how a menu starts lying about what it wrote.
private struct ClientLogCopyReceipt {
    let count: Int
    let scope: ClientLogCopyScope
}

/// What the one upload of this sheet's lifetime did. `nil` until the owner presses the button: this
/// sheet never sends on its own, and a saved path or a refusal is the record of a press.
private enum ClientLogSendOutcome {
    case saved(ClientLogUploadReceipt)
    case failed(String)
}

/// Settings → View log.
///
/// The app's own memory of what it did and where it failed, in the one place a user can reach it
/// after a screen only told them "something went wrong". It is deliberately plain: a monospaced
/// list with errors marked — because the reader is either scanning for the failure's clock time or
/// handing the log to whoever will read it.
///
/// **Two ways out, for two different readers.** A copy goes into a chat, so it takes a *portion*
/// (the newest 100 or 500 lines, or the lines on screen) as readily as the whole thing. A press of
/// Send log to host leaves a file on the machine the app is paired to — the owner's own request:
/// "wouldn't it better if u save the log on server side as well so that i wont have to paste the
/// whole log for u to investigate?"
///
/// **One view for both apps.** The phone reaches it from Settings → Diagnostics, the Mac from
/// Settings → About; both present *this* struct, and every control lives in the sheet's own header
/// rather than in a toolbar. Build 442 reported the Mac sheet offering fewer options than the
/// phone's: two copies of a toolbar are two chances to disagree, and a Mac sheet's toolbar is also
/// the first place macOS hides a button it thinks does not fit (the chevron that swallowed the
/// order control). Controls inside the content cannot be swallowed, so the two apps cannot drift.
///
/// Build 0.1.611 proved the point again from the other side: the Copy, Share and Clear buttons were
/// `ToolbarItem`s, and the owner photographed a Mac sheet whose only buttons were Close and
/// Refresh. Copy, share, send and clear now sit in the body beside the entry count, where the filter
/// controls have always been — so they are visible however the sheet is presented.
public struct ClientLogView: View {
    private let title: String
    private let header: String
    /// The host's door for a saved log, or nil when this device is not paired with one. Resolved by
    /// the app shell (a ticket is minted per press), never built here: `HermeyUI` knows no host.
    private let uploader: ClientLogUploadClient?

    @Environment(\.dismiss) private var dismiss
    /// The lines on screen and whether new ones are taken as they are written.
    @StateObject private var feed = ClientLogFeed()

    /// Which end reads first, remembered per device. `ClientLogOrder.storageKey` is the string form
    /// build 442's Bool could not express (`hermey.logOrder`); the old key is still read so an
    /// upgrading reader keeps their choice.
    @AppStorage(ClientLogOrder.storageKey) private var storedOrder = ""

    /// The narrowing the reader has asked for. Ordering and filtering themselves live in
    /// `ClientLogQuery` (HermesKit), where they are testable without a view.
    @State private var levelFilter: ClientLogLevel?
    @State private var categoryFilter: String?
    @State private var search = ""

    /// What the last copy wrote, and which list it came from. A count, not a flag: "Copied" alone
    /// leaves the reader unsure whether the filter narrowed the export, or whether the lines a
    /// paused tail was holding back went with it. `nil` means nothing was written, or the
    /// confirmation has expired.
    @State private var copied: ClientLogCopyReceipt?
    /// Bumped on every copy so an earlier confirmation's timer cannot clear a newer one.
    @State private var copySequence = 0
    @State private var confirmingClear = false
    /// Bumped when the reader asks to be taken back to the newest line (resuming a paused tail, or
    /// flipping the order). A counter rather than a Bool so two requests in a row both land.
    @State private var jumpToken = 0
    /// A press of "Send log to host" is in flight: the button spins and cannot be pressed twice.
    @State private var sending = false
    /// What that press did — the path the host answered with, or the sentence it was refused in.
    /// Both are drawn inside the sheet, because a failure that dismisses the sheet takes the log the
    /// reader was about to explain with it.
    @State private var sendOutcome: ClientLogSendOutcome?

    /// - Parameters:
    ///   - title: the sheet's title.
    ///   - header: the context line above the log (build, platform, host, connection state).
    ///   - uploader: where "Send log to host" posts, from the app shell. Nil on a device with no
    ///     paired host — the button then says so instead of offering a press that cannot work.
    public init(title: String = "Log",
                header: String = "",
                uploader: ClientLogUploadClient? = nil) {
        self.title = title
        self.header = header
        self.uploader = uploader
    }

    // MARK: The reader's choice

    private var order: ClientLogOrder {
        if let saved = ClientLogOrder(rawValue: storedOrder) { return saved }
        return ClientLogOrder.stored()
    }

    private var orderBinding: Binding<ClientLogOrder> {
        Binding(get: { order },
                set: { newOrder in
                    storedOrder = newOrder.rawValue
                    newOrder.store()
                })
    }

    private var query: ClientLogQuery {
        ClientLogQuery(order: order, level: levelFilter, category: categoryFilter, search: search)
    }

    /// What the list shows: the filter applied to the live feed, in the chosen order.
    ///
    /// Recomputed from the model on every pass, which is the point — there is no second copy of the
    /// order in view state that could go stale, which is what made build 442's toggle look inert.
    private var shown: [ClientLogEntry] { query.apply(to: feed.entries) }

    // MARK: Body

    public var body: some View {
        // The one modifier the two platforms spell differently, kept out of the chain: an
        // `.inline` bar title is iOS-only, and `#if` inside a modifier chain is a compile risk
        // that is not worth a title's height.
        #if os(iOS)
        sheetBody.navigationBarTitleDisplayMode(.inline)
        #else
        sheetBody.frame(minWidth: 520, minHeight: 420)
        #endif
    }

    private var sheetBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !header.isEmpty { headerBar }
                controls
                Hairline(color: Tokens.border)
                content
            }
            .background(Tokens.canvas)
            .navigationTitle(title)
            .toolbar { toolbar }
            .confirmationDialog("Clear this log?", isPresented: $confirmingClear,
                                titleVisibility: .visible) {
                Button("Clear log", role: .destructive) {
                    ClientLog.shared.clear()
                    feed.reload()
                }
                .hermeyFocusQuiet()
                Button("Keep it", role: .cancel) {}
                .hermeyFocusQuiet()
            } message: {
                Text("The entries are deleted from this device. Nothing on the host changes.")
            }
            .task { feed.start() }
            .onDisappear { feed.stop() }
            // A category that was filtered on and then cleared out of the ring would leave the
            // picker pointing at nothing and the list showing nothing, which reads as a broken
            // filter rather than an empty log.
            .onChange(of: feed.entries.count) { _, _ in
                if let selected = categoryFilter,
                   !ClientLog.categories(in: feed.entries).contains(selected) {
                    categoryFilter = nil
                }
            }
        }
    }

    private var headerBar: some View {
        Text(header)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Tokens.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Tokens.surface)
            .textSelection(.enabled)
    }

    // MARK: Controls
    //
    // Every option the two apps have, in the sheet rather than in a toolbar: search, level,
    // category, order, live pause, entry count, and — in their own row under it — the copy menu,
    // share, send to host and clear. The count and the pause state are always phrased in words, not
    // only in a highlight.

    private var controls: some View {
        VStack(spacing: 6) {
            searchField
            HStack(spacing: 8) {
                orderPicker
                liveButton
                if !feed.isLive, feed.heldWhilePaused > 0 {
                    Text("\(feed.heldWhilePaused) new")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Tokens.accentText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Tokens.accentSoft))
                        .accessibilityLabel("\(feed.heldWhilePaused) lines written while paused")
                }
            }
            HStack(spacing: 8) {
                levelPicker
                categoryPicker
                Spacer(minLength: 4)
                Text(copiedNotice ?? countLine)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(copied == nil ? Tokens.textDim : Tokens.accentText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel(copiedNotice ?? countLine)
            }
            handoffControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Tokens.canvas)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Tokens.textDim)

            TextField("Search the log", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.textPrimary)
                .logSearchConventions()

            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
                .hermeyFocusQuiet()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                .fill(Tokens.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                .strokeBorder(Tokens.border, lineWidth: 1)
        )
    }

    /// Two choices, two different words, and a highlight that says which one is on. Build 442's
    /// menu read "Newest first / Newest last" — one word of difference in the wrong place — and a
    /// menu shows its selection only while it is open, so the toolbar glyph looked identical either
    /// way.
    private var orderPicker: some View {
        Picker(selection: orderBinding) {
            ForEach(ClientLogOrder.allCases) { option in
                Text(option.title).tag(option)
            }
        } label: {
            Text("Order")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Order")
        .accessibilityValue(order.detail)
        .help(order.detail)
        .frame(maxWidth: .infinity)
        .hermeyFocusQuiet()
    }

    private var levelPicker: some View {
        Picker(selection: $levelFilter) {
            Text("All levels").tag(ClientLogLevel?.none)
            ForEach(ClientLogLevel.allCases, id: \.self) { level in
                Text(level.filterName).tag(ClientLogLevel?.some(level))
            }
        } label: {
            Text("Level")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Level")
        .hermeyFocusQuiet()
    }

    private var categoryPicker: some View {
        Picker(selection: $categoryFilter) {
            Text("All categories").tag(String?.none)
            ForEach(ClientLog.categories(in: feed.entries), id: \.self) { name in
                Text(name).tag(String?.some(name))
            }
        } label: {
            Text("Category")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Category")
        .hermeyFocusQuiet()
    }

    /// Pause is the difference between a log that scrolls under the reader's eyes and one that
    /// holds still while they read it. While paused the count of lines held back is on screen, so
    /// nothing is dropped silently.
    private var liveButton: some View {
        Button {
            if feed.isLive {
                feed.isLive = false
            } else {
                feed.resume()
                jumpToken += 1
            }
        } label: {
            Image(systemName: feed.isLive ? "pause.fill" : "play.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(feed.isLive ? Tokens.textSecondary : Tokens.accentText)
                .frame(width: 26, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                        .fill(Tokens.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                        .strokeBorder(feed.isLive ? Tokens.border : Tokens.accent.opacity(0.6),
                                      lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(feed.isLive ? "Pause the live tail" : "Resume the live tail")
        .accessibilityLabel(feed.isLive ? "Pause the live tail" : "Resume the live tail")
        .hermeyFocusQuiet()
    }

    private var countLine: String {
        if query.isFiltering {
            return "\(shown.count) of \(feed.entries.count)"
        }
        let total = feed.entries.count
        return "\(total) \(total == 1 ? "entry" : "entries")"
    }

    /// What the count line says for a moment after a copy: the number is the point. "Copied" on its
    /// own cannot tell the reader whether the filter went with it, and a bare "Copied" is also how a
    /// sheet lies about an export it never wrote. The scope's own sentence is used so the menu, the
    /// copy and this line cannot describe three different lists.
    private var copiedNotice: String? {
        guard let copied else { return nil }
        return copied.scope.receipt(count: copied.count)
    }

    // MARK: Handing the log to someone else

    /// Copy, share, send and clear — in the sheet's body, not its toolbar.
    ///
    /// They were toolbar items until build 0.1.611, where the Mac sheet drew Close and Refresh and
    /// dropped the rest; a control the sheet cannot show is not a control. These sit under the
    /// filter row, in the same column as the entry count, and both platforms get this one row.
    private var handoffControls: some View {
        // One row when the sheet is wide enough, two when it is not: an iPhone in portrait with a
        // Dynamic Type bump should wrap rather than clip a word off "Send log to host".
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    copyMenu
                    shareButton
                    sendButton
                    Spacer(minLength: 4)
                    clearButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        copyMenu
                        shareButton
                        Spacer(minLength: 4)
                        clearButton
                    }
                    sendButton
                }
            }
            sendStatus
        }
    }

    /// The four copies, in one menu: the newest 100 lines, the newest 500, the lines on screen, or
    /// everything the filter admits. Each item carries the size of the pool it would take — "(of 812)"
    /// — because the complaint that produced this menu was that a copy took the whole log and there was
    /// no way to ask for less: "would be better if i could just copy a portion of the log like last 100
    /// lines and so on instead of copying the whole thing".
    ///
    /// The counts are read at draw time from the same query the copy uses, so a filter typed a moment
    /// ago is already reflected in the numbers.
    private var copyMenu: some View {
        Menu {
            ForEach(ClientLogCopyScope.allCases) { scope in
                Button(scope.title(available: availableCount(scope))) {
                    copy(scope)
                }
                .disabled(availableCount(scope) == 0)
                .help(copyHelp(scope))
            }
        } label: {
            handoffLabel("Copy…", "doc.on.doc")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(logAdmittedCount == 0 && shown.isEmpty)
        .opacity(logAdmittedCount == 0 && shown.isEmpty ? 0.45 : 1)
        .help("Copy a portion of the log, or all of it")
        .accessibilityLabel("Copy")
        .accessibilityHint("Offers the newest 100 lines, the newest 500, the lines on screen, or all of them")
        .hermeyFocusQuiet()
    }

    /// The sentence under each menu item, so the difference between four copies is not a guess.
    private func copyHelp(_ scope: ClientLogCopyScope) -> String {
        switch scope {
        case .last100: return "Copy the newest 100 lines the filter admits"
        case .last500: return "Copy the newest 500 lines the filter admits"
        case .shown: return "Copy the lines on screen, in the order they are in"
        case .all: return "Copy every line the filter admits, including lines a paused tail is holding back"
        }
    }

    /// The same text as Copy shown, handed to the system's share sheet — the phone's route to
    /// Messages or Mail instead of only to the clipboard.
    private var shareButton: some View {
        ShareLink(item: exportText(shown)) {
            handoffLabel("Share log", "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        .disabled(shown.isEmpty)
        .opacity(shown.isEmpty ? 0.45 : 1)
        .help("Send the lines on screen to another app")
        .accessibilityLabel("Share log")
        .hermeyFocusQuiet()
    }

    /// One tap, one file on the host. Not a button that also copies, and not a background sync: the
    /// owner asked to stop pasting the log into a chat, not to have the app send it without being asked.
    private var sendButton: some View {
        Button {
            sendLog()
        } label: {
            HStack(spacing: 4) {
                handoffLabel("Send log to host", "arrow.up.doc")
                if sending { ProgressView().controlSize(.mini) }
            }
        }
        .buttonStyle(.plain)
        .disabled(uploader == nil || sending || logAdmittedCount == 0)
        .opacity(uploader == nil || logAdmittedCount == 0 ? 0.45 : 1)
        .help(uploader == nil
              ? "No host is paired with this device, so there is nowhere to save the log"
              : "Save this log as a file on the host, where it can be read without pasting it")
        .accessibilityLabel("Send log to host")
        .accessibilityHint("Saves the log as a file on the paired host and shows the path")
        .hermeyFocusQuiet()
    }

    /// What the press did, under the row it was pressed in: the path on success (the one fact the
    /// owner can act on), or the reason on failure. The sheet stays open either way.
    @ViewBuilder
    private var sendStatus: some View {
        if sending {
            Text("Sending the log to the host…")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Tokens.textMuted)
        } else if let sendOutcome {
            switch sendOutcome {
            case let .saved(receipt):
                Text("Saved on the host: \(receipt.path)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Tokens.accentText)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityLabel("Saved on the host at \(receipt.path)")
            case let .failed(reason):
                Text("Not sent — \(reason)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("The log was not sent: \(reason)")
            }
        }
    }

    private var clearButton: some View {
        Button {
            confirmingClear = true
        } label: {
            handoffLabel("Clear", "trash")
        }
        .buttonStyle(.plain)
        .disabled(feed.entries.isEmpty)
        .opacity(feed.entries.isEmpty ? 0.45 : 1)
        .help("Delete the entries on this device")
        .accessibilityLabel("Clear log")
        .hermeyFocusQuiet()
    }

    /// One look for every control in that row: a small capsule in the app's control colour with a
    /// word on it. Icons alone are exactly what the owner could not find.
    private func handoffLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Tokens.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                    .fill(Tokens.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                    .strokeBorder(Tokens.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if feed.entries.isEmpty {
            emptyState
        } else if shown.isEmpty {
            noMatchesState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { entry in
                            row(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    // Selection is set on every row *and* here, so a future row built from more than
                    // one `Text` inherits it rather than silently losing the ability to be read.
                    .textSelection(.enabled)
                }
                .scrollDismissesKeyboard(.interactively)
                // Flipping the order is a request to read from the other end: follow the newest
                // line to wherever it now sits, rather than leaving the scroll where a different
                // list used to be. This is what "keeps the position on the newest entry" means.
                .onChange(of: order) { _, newOrder in
                    jumpToNewest(proxy, anchor: newOrder == .newestFirst ? .top : .bottom)
                }
                .onChange(of: jumpToken) { _, _ in
                    jumpToNewest(proxy, anchor: order == .newestFirst ? .top : .bottom)
                }
            }
        }
    }

    private func row(_ entry: ClientLogEntry) -> some View {
        Text(entry.line)
            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
            .foregroundStyle(tint(entry.level))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A row is a `Text`, so this is the only selection SwiftUI offers here: a long-press
            // picks the run up with the system's own select/copy menu, and a drag inside a wrapped
            // line selects part of it. Selection within a row does not stop the scroll from
            // working, and the row has no tap of its own, so nothing competes with it. For more
            // than one row, "Copy shown" is the answer.
            .textSelection(.enabled)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(Tokens.textDim)
            Text("Nothing logged yet")
                .font(TypeScale.font(TypeScale.lg, weight: .medium))
                .foregroundStyle(Tokens.textPrimary)
            Text("The app writes here when it connects, fails, retries or loses a message — so the next problem leaves a trail.")
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Nothing matches" is a different fact from "nothing was logged", and the empty state has to
    /// say which one it is or the reader goes looking for a bug that is not there.
    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 22))
                .foregroundStyle(Tokens.textDim)
            Text("No lines match")
                .font(TypeScale.font(TypeScale.lg, weight: .medium))
                .foregroundStyle(Tokens.textPrimary)
            Text(filterSummary)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Show every line") {
                levelFilter = nil
                categoryFilter = nil
                search = ""
            }
            .font(TypeScale.font(TypeScale.md))
            .padding(.top, 2)
            .hermeyFocusQuiet()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filterSummary: String {
        var parts: [String] = []
        if !query.trimmedSearch.isEmpty { parts.append("“\(query.trimmedSearch)”") }
        if let levelFilter { parts.append(levelFilter.filterName) }
        if let categoryFilter { parts.append(categoryFilter) }
        return parts.joined(separator: " · ")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }
                .font(TypeScale.font(TypeScale.md))
                .hermeyFocusQuiet()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // Re-read without closing the sheet: a log that is only read on open cannot show the
            // line a paused tail is holding back.
            Button {
                feed.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Read the log again")
            .hermeyFocusQuiet()
            // Copy, share and clear are deliberately *not* here: see `handoffControls`. On the Mac
            // this group is exactly what the sheet dropped in build 0.1.611.
        }
    }

    // MARK: Behaviour

    private func tint(_ level: ClientLogLevel) -> Color {
        switch level {
        case .info: return Tokens.textSecondary
        case .warning: return Tokens.warning
        case .error: return Tokens.danger
        }
    }

    /// The newest line, if the current filter still shows it — there is nothing to scroll to when
    /// the reader has filtered it out.
    private var newestShownID: ClientLogEntry.ID? {
        guard let newest = feed.entries.last?.id,
              shown.contains(where: { $0.id == newest }) else { return nil }
        return newest
    }

    private func jumpToNewest(_ proxy: ScrollViewProxy, anchor: UnitPoint) {
        guard let id = newestShownID else { return }
        // One hop, because the list it scrolls to is the list this change is about to build.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }

    /// What Copy and Share hand over: the header, then the lines *as the reader is reading them*.
    /// A log copied in newest-first order pastes into a message newest-first, which is the order
    /// the person on the other end will look for the failure in.
    ///
    /// The one formatter. Both copy actions call it with a different list; neither builds its own
    /// string, so the two can only differ in *which* lines they hand over.
    private func exportText(_ entries: [ClientLogEntry]) -> String {
        ClientLog.text(of: entries, header: header)
    }

    /// Every line the log holds that the filter admits, in the reader's order, with the newest
    /// `limit` kept when the scope is a tail.
    ///
    /// Read from the log rather than from `feed.entries` because a paused tail holds new lines back
    /// in the feed — and "all" is the one action whose meaning includes them. Copying is not a
    /// request to resume, so the tail stays paused.
    private func logEntries(limit: Int?) -> [ClientLogEntry] {
        ClientLog.shared.flushNow()
        let buffer = ClientLog.shared.snapshot()
        return query.apply(to: buffer, limit: limit)
    }

    /// How many lines the log would hand this scope, for the label. Read without the flush: a count
    /// must not write to disk on every redraw, and the buffer is the same list the flush writes.
    private var logAdmittedCount: Int {
        query.apply(to: ClientLog.shared.snapshot()).count
    }

    /// The pool a scope copies from, counted. `shown` is the feed (what the reader is looking at);
    /// the other three read the log, so a paused tail does not make "all" smaller than it is.
    private func availableCount(_ scope: ClientLogCopyScope) -> Int {
        scope == .shown ? shown.count : logAdmittedCount
    }

    private func copy(_ scope: ClientLogCopyScope) {
        switch scope {
        case .shown:
            copy(shown, scope: .shown)
        case .all, .last100, .last500:
            copy(logEntries(limit: scope.lineLimit), scope: scope)
        }
    }

    private func copy(_ entries: [ClientLogEntry], scope: ClientLogCopyScope) {
        // Never claim a copy that wrote nothing. The buttons are already disabled on an empty
        // source; this is the second lock on the same door, because a receipt is a promise.
        guard !entries.isEmpty else { return }
        ClientLog.shared.flushNow()
        write(exportText(entries))
        announce(ClientLogCopyReceipt(count: entries.count, scope: scope))
    }

    private func write(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// Show what was written, then put the count back. The sequence number is what keeps a second
    /// copy's receipt from being cleared by the first copy's timer.
    private func announce(_ receipt: ClientLogCopyReceipt) {
        copySequence += 1
        let sequence = copySequence
        copied = receipt
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard sequence == copySequence else { return }
            copied = nil
        }
    }

    // MARK: Saving the log on the host

    /// One tap: the same bytes a copy would write, posted to the host, which answers with the path.
    ///
    /// Nothing here is automatic. The sheet does not send on appear, on an error, or after a copy —
    /// the owner asked for a place to read the log, not for the app deciding when to send it. The
    /// scope is *all* (everything the filter admits, paused-held lines included) because the file is
    /// meant to be the whole answer for whoever reads it on the host; the filter that produced it
    /// travels in the envelope, so a file narrowed to errors says why it is short.
    private func sendLog() {
        guard let uploader, !sending else { return }
        let entries = logEntries(limit: nil)
        guard !entries.isEmpty else { return }
        sending = true
        sendOutcome = nil
        let payload = ClientLogUploadPayload(
            device: Self.deviceName,
            appVersion: Self.bundleValue("CFBundleShortVersionString"),
            appBuild: Self.bundleValue("CFBundleVersion"),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            scope: .all,
            level: levelFilter?.filterName,
            category: categoryFilter,
            search: query.trimmedSearch.isEmpty ? nil : query.trimmedSearch,
            // The UTC moment this file describes; the host writes its own stamp in the filename.
            capturedAt: Date(),
            text: exportText(entries))
        Task {
            do {
                let receipt = try await uploader.send(payload)
                sendOutcome = .saved(receipt)
            } catch {
                // Every case of `ClientLogUploadError` has its own sentence, and the sheet keeps
                // itself open with it: a 403, a 413 and an unreachable host are three different
                // problems and the reader is the one who can act on any of them.
                sendOutcome = .failed(error.localizedDescription)
            }
            sending = false
        }
    }

    /// This device's own name, as its owner set it in Settings — what the host's filename carries.
    /// Read here rather than in `HermesKit` so that module stays Foundation-only, and spelled the
    /// same way `SettingsScreen.logHeader` already reads the OS name beside it.
    private static var deviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }

    private static func bundleValue(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
}

// MARK: - Platform spellings

private extension View {
    /// A log search is a literal fragment of output: no autocapitalisation, no autocorrection. Both
    /// spellings are iOS-only, and a `#if` inside a modifier chain is the compile risk the file
    /// above goes out of its way to avoid.
    @ViewBuilder
    func logSearchConventions() -> some View {
        #if os(iOS)
        self.autocorrectionDisabled().textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}

// MARK: - The live half

/// The lines on screen, whether new ones are taken, and how many arrived while they were not.
///
/// This is the only part of the viewer that needs a UI framework, which is why it lives here and
/// not in HermesKit: the ordering and filtering it feeds are `ClientLogQuery`, which is Foundation
/// only and is tested in `ClientLogTests`.
final class ClientLogFeed: ObservableObject {
    @Published private(set) var entries: [ClientLogEntry] = []
    /// Lines written while the tail was paused. Counted rather than kept: "3 new" is the fact the
    /// reader needs, and a paused sheet that grows in the background is the thing pause exists to
    /// prevent.
    @Published private(set) var heldWhilePaused = 0
    /// Whether a line written now reaches the list now.
    @Published var isLive = true

    private let log: ClientLog
    private let capacity: Int
    private var observer: ClientLogObserver?

    init(log: ClientLog = .shared) {
        self.log = log
        self.capacity = log.capacity
    }

    deinit {
        if let observer { log.stopObserving(observer) }
    }

    /// Read the log and start following it. Called from the sheet's `task`; calling it twice is a
    /// no-op rather than a second subscription.
    func start() {
        reload()
        guard observer == nil else { return }
        observer = log.observe { [weak self] entry in
            // The log calls back on its own queue (see `ClientLog.observe`), so the hop to the main
            // queue is not politeness — reading `@Published` off-main is a runtime warning and an
            // update SwiftUI may drop.
            DispatchQueue.main.async { self?.receive(entry) }
        }
    }

    /// Stop following the log. The sheet's `onDisappear` calls this; a viewer left registered would
    /// keep a dead view's state alive and redraw a sheet nobody is looking at.
    func stop() {
        if let observer { log.stopObserving(observer) }
        observer = nil
    }

    /// Re-read the whole log (Refresh, Clear, and coming back from a pause).
    func reload() {
        entries = log.snapshot()
        heldWhilePaused = 0
    }

    /// Take up everything that was held back and follow the log again.
    func resume() {
        isLive = true
        reload()
    }

    private func receive(_ entry: ClientLogEntry) {
        guard isLive else {
            heldWhilePaused += 1
            return
        }
        entries.append(entry)
        // The same bound the file keeps: live appends must not let the sheet outgrow the ring.
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }
}

#if DEBUG
#Preview("Log") {
    ClientLogView(header: "Hermey 0.1.442 (build 442)\niOS 18.2 · host: casa · direct")
        .preferredColorScheme(.dark)
}
#endif
