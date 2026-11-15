import Combine
import SwiftUI
import HermesKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Settings → View log.
///
/// The app's own memory of what it did and where it failed, in the one place a user can reach it
/// after a screen only told them "something went wrong". It is deliberately plain: a monospaced
/// list with errors marked — because the reader is either scanning for the failure's clock time or
/// copying the whole thing into a message.
///
/// **One view for both apps.** The phone reaches it from Settings → Diagnostics, the Mac from
/// Settings → About; both present *this* struct, and every control lives in the sheet's own header
/// rather than in a toolbar. Build 442 reported the Mac sheet offering fewer options than the
/// phone's: two copies of a toolbar are two chances to disagree, and a Mac sheet's toolbar is also
/// the first place macOS hides a button it thinks does not fit (the chevron that swallowed the
/// order control). Controls inside the content cannot be swallowed, so the two apps cannot drift.
public struct ClientLogView: View {
    private let title: String
    private let header: String

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

    @State private var copied = false
    @State private var confirmingClear = false
    /// Bumped when the reader asks to be taken back to the newest line (resuming a paused tail, or
    /// flipping the order). A counter rather than a Bool so two requests in a row both land.
    @State private var jumpToken = 0

    /// - Parameters:
    ///   - title: the sheet's title.
    ///   - header: the context line above the log (build, platform, host, connection state).
    public init(title: String = "Log", header: String = "") {
        self.title = title
        self.header = header
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
                Button("Keep it", role: .cancel) {}
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
    // category, order, live pause, entry count, and (in the toolbar) refresh, copy, share, clear.
    // The count and the pause state are always phrased in words, not only in a highlight.

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
                Text(countLine)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Tokens.textDim)
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel(countLine)
            }
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
    }

    private var countLine: String {
        if query.isFiltering {
            return "\(shown.count) of \(feed.entries.count)"
        }
        let total = feed.entries.count
        return "\(total) \(total == 1 ? "entry" : "entries")"
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

            Button {
                copy()
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(shown.isEmpty)
            .help("Copy the lines on screen")

            ShareLink(item: exportText()) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(shown.isEmpty)

            Button {
                confirmingClear = true
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(feed.entries.isEmpty)
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
    private func exportText() -> String {
        ClientLog.text(of: shown, header: header)
    }

    private func copy() {
        ClientLog.shared.flushNow()
        let text = exportText()
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = false
        }
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
