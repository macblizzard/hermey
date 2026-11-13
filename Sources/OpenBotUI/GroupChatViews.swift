import SwiftUI
import UniformTypeIdentifiers
import HermesKit
#if canImport(AVFoundation)
import AVFoundation
#endif
#if os(macOS)
import AppKit
#else
import PhotosUI
import UIKit
#endif

/// Group chats, written once for both apps.
///
/// A group chat is a **hosted Hermes room**: the host owns the roster and a monotonic log, and its
/// driver decides which members answer. The app is a reader of that log plus a composer — so the
/// transcript here is rendered from `seq`-ordered events, not from anything this client assembles.
/// That is why a bot answering another bot shows up without the owner doing anything: it was never
/// this app's message to route.

// MARK: - Start

/// Pick a name and 2–6 bots.
public struct StartGroupChatSheet: View {
    private let bots: [Bot]
    private let icons: [String: BotIcon]
    private let onCreate: (String, [String]) async throws -> RoomSummary
    private let onCreated: (RoomSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picked: [String] = []
    @State private var busy = false
    @State private var failure: String?

    public init(bots: [Bot], icons: [String: BotIcon],
                onCreate: @escaping (String, [String]) async throws -> RoomSummary,
                onCreated: @escaping (RoomSummary) -> Void) {
        self.bots = bots
        self.icons = icons
        self.onCreate = onCreate
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Name the group (optional)", text: $name)
                    .font(TypeScale.font(TypeScale.md))
                    .padding(12)
                    .background(Tokens.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(16)

                HStack {
                    Text("WHO IS IN IT")
                        .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                        .foregroundStyle(Tokens.textMuted)
                    Spacer()
                    Text("\(picked.count) of 2–6")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(picked.count >= 2 ? Tokens.textMuted : Tokens.warning)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 6)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(bots) { bot in
                            memberRow(bot)
                        }
                    }
                    .padding(.horizontal, 12)
                }

                if let failure {
                    Text(failure)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.danger)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .background(Tokens.canvas)
            .navigationTitle("New group chat")
            .inlineSheetTitle()
            .sheetSizing(minWidth: 420, minHeight: 520)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Start") { Task { await create() } }
                            .disabled(!(2...6).contains(picked.count))
                    }
                }
            }
        }
    }

    private func memberRow(_ bot: Bot) -> some View {
        let isPicked = picked.contains(bot.id)
        return Button {
            if isPicked { picked.removeAll { $0 == bot.id } }
            else if picked.count < 6 { picked.append(bot.id) }
        } label: {
            HStack(spacing: 10) {
                BotIconPortrait(icons[bot.id] ?? BotIcon.default(for: bot.id), size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bot.displayName)
                        .font(TypeScale.font(TypeScale.md, weight: .medium))
                        .foregroundStyle(Tokens.textPrimary)
                    if let described = bot.description, !described.isEmpty {
                        Text(described)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textDim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isPicked ? Tokens.accent : Tokens.textDim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(isPicked ? Tokens.accentSoft : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func create() async {
        busy = true
        failure = nil
        do {
            let room = try await onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines), picked)
            dismiss()
            onCreated(room)
        } catch {
            failure = error.localizedDescription
        }
        busy = false
    }
}

// MARK: - List

/// The rooms this host already has.
public struct GroupChatsSheet: View {
    private let load: () async throws -> [RoomSummary]
    private let onOpen: (RoomSummary) -> Void
    private let onNew: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rooms: [RoomSummary] = []
    @State private var loading = true
    @State private var failure: String?

    public init(load: @escaping () async throws -> [RoomSummary],
                onOpen: @escaping (RoomSummary) -> Void,
                onNew: @escaping () -> Void) {
        self.load = load
        self.onOpen = onOpen
        self.onNew = onNew
    }

    public var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rooms.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.3")
                            .font(.system(size: 24))
                            .foregroundStyle(Tokens.textDim)
                        Text("No group chats yet")
                            .font(TypeScale.font(TypeScale.lg, weight: .medium))
                            .foregroundStyle(Tokens.textPrimary)
                        Text("Put two or more bots in one room and they can read and answer each other.")
                            .font(TypeScale.font(TypeScale.sm))
                            .foregroundStyle(Tokens.textMuted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(rooms) { room in
                        Button {
                            dismiss()
                            onOpen(room)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(room.name)
                                    .font(TypeScale.font(TypeScale.md, weight: .medium))
                                    .foregroundStyle(Tokens.textPrimary)
                                Text(room.members.map(\.displayName).joined(separator: ", "))
                                    .font(TypeScale.font(TypeScale.caption))
                                    .foregroundStyle(Tokens.textDim)
                                    .lineLimit(1)
                                if let at = room.updatedAt {
                                    Text(RelativeTime.stamp(at))
                                        .font(TypeScale.font(TypeScale.micro))
                                        .foregroundStyle(Tokens.textDim)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        // Same three lines the phone's list needs: a `.plain` List otherwise draws
                        // its own (black, in dark mode) cell background and separators over the
                        // app's canvas.
                        .listRowBackground(Tokens.canvas)
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Tokens.canvas)
            .navigationTitle("Group chats")
            .inlineSheetTitle()
            .sheetSizing()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { dismiss(); onNew() } label: { Label("New", systemImage: "plus") }
                }
            }
            .task {
                do { rooms = try await load() } catch { failure = error.localizedDescription }
                loading = false
            }
        }
    }
}

// MARK: - Room

/// One room's conversation.
///
/// Polls `groups.log` after the highest `seq` it has instead of holding a socket: the host's log is
/// monotonic, so a delta is cheap, and a dropped poll costs nothing but a slightly later line. The
/// alternative — keeping a second websocket open inside the chat — would compete with the
/// conversation socket for the same ticket machinery.
public struct RoomChatView: View {
    #if os(macOS) && canImport(AVFoundation)
    /// The Mac reads locally: it has no server-side voice path and no ringer switch to mute it.
    private static let speaker = AVSpeechSynthesizer()
    #endif

    /// Where the room is drawn. The chat is the same in all three; only the chrome differs — a sheet
    /// needs its own navigation bar to have a Close button, a pushed screen borrows the stack's, and
    /// the Mac's conversation pane has no navigation bar at all.
    public enum Presentation { case sheet, pushed, pane }

    private let room: RoomSummary
    private let presentation: Presentation
    private let icons: [String: BotIcon]
    private let load: (String, Int?) async throws -> RoomPage
    private let send: (String, String, [RoomAttachment]) async throws -> Void
    /// Called after the newest message arrives, so the list row behind this window keeps up.
    private let onActivity: (() -> Void)?
    /// The room's high-water `seq`, reported whenever it moves. The model turns it into the
    /// device's read mark, which is what keeps a room you are looking at from badging itself.
    private let onLatestSeq: ((Int) -> Void)?
    /// Only the pane uses this: outside a sheet there is nothing for `dismiss()` to dismiss.
    private let onClose: (() -> Void)?
    /// The pane's own chrome, the same verbs the Mac puts on a bot's header.
    private let sidebarHidden: Bool
    private let onToggleSidebar: (() -> Void)?
    private let onDelete: (() -> Void)?
    /// Renaming happens in the room, not in a sheet: a sheet raised from the list competed with
    /// the list's own presentations and never appeared on either platform.
    private let onRename: ((String) async throws -> Void)?
    /// The room the list's long-press menu asked to rename, by id. Rename has exactly one entry
    /// point — the row's context menu — so the room carries no Rename button; the menu names a
    /// room, this room sees its own id and opens its name field. The view clears it when consumed.
    private let renameSignal: Binding<String?>
    /// Read a message out loud. Supplied by the phone (the host's TTS, through the same audio
    /// session a conversation uses); absent on the Mac, which speaks locally.
    private let speak: ((String) async throws -> Void)?
    /// A message body drawn by the platform's own markdown renderer — the same one a conversation
    /// uses, so a room's reply is bold, tabular and code-highlighted exactly like a chat reply
    /// instead of showing `**stars**` and pipe characters.
    private let markdown: ((String) -> AnyView)?
    /// ⌘R from the shell, as a number: a changed value means "read the room again".
    private let refreshSignal: Int

    @Environment(\.dismiss) private var dismiss
    @State private var messages: [RoomMessage] = []
    @State private var draft = ""
    @State private var latestSeq = 0
    @State private var loading = true
    @State private var sending = false
    @State private var failure: String?
    @State private var mentionQuery: String?
    /// The Mac explains the keyboard; the phone has no hint line, and a line of "⏎ send" over a
    /// touch keyboard is noise.
    #if os(macOS)
    private let composerHint: String? = "⏎ send · ⇧⏎ newline · @ to pick a bot"
    #else
    private let composerHint: String? = nil
    #endif

    @State private var findOpen = false
    /// Files picked but not yet sent: the same bargain a bot's composer makes.
    @State private var pendingFiles: [RoomAttachment] = []
    @State private var showingImporter = false
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var title = ""
    @State private var renameFailure: String?
    #if os(iOS)
    /// The phone attaches the way the phone does: a picture from the library, or any file.
    @State private var showingAttachOptions = false
    @State private var showingPhotos = false
    @State private var photoItem: PhotosPickerItem?
    #endif
    @State private var findQuery = ""
    /// One reaction per message, kept on the device like a conversation's: the host's room log has
    /// no reaction verb, so claiming to store it on the host would be a lie.
    @AppStorage("room.messageReactions.v1") private var storedReactions = "{}"
    /// Which message the reaction popover is open for.
    @State private var reactingSeq: Int?
    private static let reactionEmoji = ["👍", "❤️", "😂", "😮", "😢", "🎉"]

    public init(room: RoomSummary, icons: [String: BotIcon],
                presentation: Presentation = .sheet,
                load: @escaping (String, Int?) async throws -> RoomPage,
                send: @escaping (String, String, [RoomAttachment]) async throws -> Void,
                onActivity: (() -> Void)? = nil,
                onLatestSeq: ((Int) -> Void)? = nil,
                onClose: (() -> Void)? = nil,
                sidebarHidden: Bool = false,
                onToggleSidebar: (() -> Void)? = nil,
                onDelete: (() -> Void)? = nil,
                onRename: ((String) async throws -> Void)? = nil,
                renameSignal: Binding<String?> = .constant(nil),
                speak: ((String) async throws -> Void)? = nil,
                markdown: ((String) -> AnyView)? = nil,
                refreshSignal: Int = 0) {
        self.room = room
        self.presentation = presentation
        self.icons = icons
        self.load = load
        self.send = send
        self.onActivity = onActivity
        self.onLatestSeq = onLatestSeq
        self.onClose = onClose
        self.sidebarHidden = sidebarHidden
        self.onToggleSidebar = onToggleSidebar
        self.onDelete = onDelete
        self.onRename = onRename
        self.renameSignal = renameSignal
        self.speak = speak
        self.markdown = markdown
        self.refreshSignal = refreshSignal
    }

    public var body: some View {
        chrome
            // A long press on the row names this room: open with the field up, or flip to it if
            // the room is already the one on screen (the Mac's sidebar can name the open room).
            .onAppear { consumeRenameSignal() }
            .onChange(of: renameSignal.wrappedValue) { _, _ in consumeRenameSignal() }
    }

    /// Start the inline rename when the list asked for *this* room, then clear the request so a
    /// second visit does not reopen the field.
    private func consumeRenameSignal() {
        guard onRename != nil, renameSignal.wrappedValue == room.id else { return }
        nameDraft = title.isEmpty ? room.name : title
        renameFailure = nil
        editingName = true
        renameSignal.wrappedValue = nil
    }

    @ViewBuilder
    private var chrome: some View {
        switch presentation {
        case .sheet:
            NavigationStack {
                core
                    .navigationTitle(room.name)
                    .inlineSheetTitle()
                    .sheetSizing(minWidth: 520, minHeight: 520)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    }
            }
        case .pushed:
            VStack(spacing: 0) {
                renameBar
                core
            }
            // The stack's own background is the system's, which is black in dark mode: without this
            // the strip above the roster and the keyboard's safe area are off-theme.
            .background(Tokens.canvas)
            .navigationTitle(title.isEmpty ? room.name : title)
            .inlineSheetTitle()
            .toolbar {
                // The same three-dot menu the Mac's pane header carries: a room has verbs, and on
                // the phone the bar was the one place they were missing.
                // `.primaryAction` is the one placement both platforms have; `.topBarTrailing`
                // does not exist on macOS and this file compiles for both.
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            // The find strip lives at the top of the transcript; asking for it
                            // from the menu is the only way to reach it on the phone.
                            findOpen = true
                        } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        Button { Task { await refresh(reset: true) } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        if let onDelete {
                            Divider()
                            Button(role: .destructive) { onDelete() } label: {
                                Label("Delete chat", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Group chat menu")
                }
            }
        case .pane:
            VStack(spacing: 0) {
                paneHeader
                Hairline(color: Tokens.border)
                renameBar
                core
            }
            .background(Tokens.canvas)
        }
    }

    /// The Mac has no navigation bar, so the pane draws its own: the room's name, its bots, a way
    /// out. Cheap, and it means a room and a bot's chat open in exactly the same rectangle.
    private var paneHeader: some View {
        HStack(spacing: 9) {
            if let onToggleSidebar {
                OpenBotIconButton(sidebarHidden ? "sidebar.leading" : "sidebar.left",
                                  label: sidebarHidden ? "Show the bot panel" : "Hide the bot panel",
                                  size: .small) {
                    onToggleSidebar()
                }
            }

            // The room's faces, not one bot's: this is the header's answer to "who is here".
            HStack(spacing: -7) {
                ForEach(Array(room.members.prefix(3))) { member in
                    BotIconPortrait(icons[member.profile] ?? BotIcon.default(for: member.profile), size: 24)
                        .overlay(Circle().stroke(Tokens.canvas, lineWidth: 1.5))
                }
            }
            .fixedSize()

            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? room.name : title)
                    .font(TypeScale.font(TypeScale.lg, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if sending {
                StatusChip("running", tone: .success, showsDot: true, size: .small)
            }

            OpenBotIconButton(findOpen ? "xmark" : "magnifyingglass",
                              label: findOpen ? "Close the find field" : "Find in this group chat",
                              size: .small) {
                findOpen.toggle()
                if !findOpen { findQuery = "" }
            }

            Menu {
                Button("Refresh") { Task { await refresh(reset: true) } }
                if let onDelete {
                    Divider()
                    Button("Delete group chat…", role: .destructive) { onDelete() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.textMuted)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 48, alignment: .leading)
        .background(Tokens.canvas)
    }

    /// "3 bots · 12 messages" — the two facts a room's header can know without asking the host.
    private var subtitle: String {
        let bots = room.members.count == 1 ? "1 bot" : "\(room.members.count) bots"
        let said = messages.filter { !$0.isOwner }.count
        guard said > 0 else { return bots }
        return "\(bots) · \(said) repl\(said == 1 ? "y" : "ies")"
    }

    /// The rename field, inline: no sheet, no alert, nothing to fail to present.
    @ViewBuilder
    private var renameBar: some View {
        if editingName {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    TextField("Group chat name", text: $nameDraft)
                        .font(TypeScale.font(TypeScale.md))
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await commitRename() } }
                    Button("Save") { Task { await commitRename() } }
                        .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.accentText)
                    Button("Cancel") { editingName = false; renameFailure = nil }
                        .font(TypeScale.font(TypeScale.caption))
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.textDim)
                }
                if let renameFailure {
                    Text(renameFailure)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.danger)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Tokens.surface)
            Hairline(color: Tokens.border)
        }
    }

    private func commitRename() async {
        let wanted = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, let onRename else { editingName = false; return }
        do {
            try await onRename(wanted)
            title = wanted
            editingName = false
            renameFailure = nil
        } catch {
            renameFailure = error.localizedDescription
        }
    }

    /// Roster, transcript, composer — the part that is the room rather than the frame around it.
    private var core: some View {
        VStack(spacing: 0) {
            roster
            Hairline(color: Tokens.border)
            if findOpen {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textDim)
                    TextField("Find in this group chat", text: $findQuery)
                        .font(TypeScale.font(TypeScale.sm))
                        .textFieldStyle(.plain)
                    Text("\(visibleMessages.count) of \(messages.count)")
                        .font(TypeScale.font(TypeScale.micro))
                        .foregroundStyle(Tokens.textDim)
                        .monospacedDigit()
                }
                .padding(.horizontal, Geometry.chatGutter)
                .padding(.vertical, 7)
                Hairline(color: Tokens.border)
            }
            transcript
            Hairline(color: Tokens.border)
            composer
        }
        .background(Tokens.canvas)
        #if os(iOS)
        .confirmationDialog("Attach to the group", isPresented: $showingAttachOptions,
                            titleVisibility: .visible) {
            Button("Photo Library") { showingPhotos = true }
            Button("File…") { showingImporter = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showingPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    pendingFiles.append(RoomAttachment(name: "photo-\(Int(Date().timeIntervalSince1970)).jpg",
                                                       data: data, isImage: true))
                }
            }
        }
        #endif
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            pendingFiles.append(contentsOf: urls.compactMap(load))
        }
        .task { await poll() }
        .onChange(of: refreshSignal) { _, _ in
            // ⌘R: re-read the whole log, not just the delta — the point of asking is that the
            // window might be showing something older than the host has.
            Task { await refresh(reset: true) }
        }
    }

    /// Who is in the room, always visible: a group chat's whole point is that several bots answer.
    private var roster: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(room.members) { member in
                    HStack(spacing: 5) {
                        BotIconPortrait(icons[member.profile] ?? BotIcon.default(for: member.profile), size: 20)
                        Text("@\(member.mention)")
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textMuted)
                    }
                }
            }
            .padding(.horizontal, Geometry.chatGutter)
            .padding(.vertical, 7)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                    }
                    ForEach(visibleMessages) { message in
                        bubble(message)
                            .id(message.seq)
                    }
                    if sending {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Sent — the bots named in the message are answering")
                                .font(TypeScale.font(TypeScale.caption))
                                .foregroundStyle(Tokens.textDim)
                        }
                        .padding(.horizontal, 4)
                        .id("pending")
                    }
                }
                // The conversation's own gutter, so a room's bubbles start exactly where a bot
                // chat's do and where this room's composer will.
                .padding(.horizontal, Geometry.chatGutter)
                .padding(.vertical, 12)
            }
            // Scrolling the transcript puts the keyboard away, the way a conversation does: reading
            // further back and typing are two different things, and the keyboard was covering the
            // room for as long as the field held focus.
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if let last = messages.last { proxy.scrollTo(last.seq, anchor: .bottom) }
                }
            }
        }
    }

    /// The find field narrows the transcript without touching what was received: the log keeps
    /// every line, the view shows the matches, so closing the field restores the conversation.
    private var visibleMessages: [RoomMessage] {
        let needle = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard findOpen, !needle.isEmpty else { return messages }
        return messages.filter {
            $0.text.localizedCaseInsensitiveContains(needle)
                || $0.speaker.localizedCaseInsensitiveContains(needle)
        }
    }

    private func bubble(_ message: RoomMessage) -> some View {
        let mine = message.isOwner
        // 16 pt of asymmetry, not 44: the side a message is on already says who said it, and two
        // bubbles per screen each giving up 44 points of a 393-point phone is most of a line of
        // text per message. The avatar shrinks with it for the same reason.
        return HStack(alignment: .top, spacing: 6) {
            if mine { Spacer(minLength: 16) }
            if !mine {
                BotIconPortrait(icons[message.speaker] ?? BotIcon.default(for: message.speaker), size: 20)
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if !mine {
                    Text("@\(message.speaker)")
                        .font(TypeScale.font(TypeScale.sm, weight: .semibold))
                        .foregroundStyle(Tokens.textMuted)
                }
                // A bot's answer is prose, and prose in this app is markdown at the chat's own
                // metrics — that is what makes a reply in a conversation readable. A room shows the
                // same renderer at full width instead of a `Text` of raw `**bold**` and pipe tables
                // inside a bubble, which is what made these messages look cramped and unreadable.
                Group {
                    if mine {
                        messageBubble(message.text, mine: true)
                    } else if let markdown {
                        markdown(message.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        messageBubble(message.text, mine: false)
                    }
                }
                // Long press a line: the two verbs a bot's message offers, so a room's transcript is
                // as quotable as a conversation's.
                .contextMenu {
                    Button { copy(message.text) } label: {
                        Label("Copy Message", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: message.text) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                // Under every message: when it was said, and the four things one does with a
                // message — listen, copy, answer it, mark it. Small and dim, because they are
                // tools, not content.
                HStack(spacing: 14) {
                    if let at = message.at {
                        Text(at.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(Tokens.textMuted)
                    }
                    messageAction("speaker.wave.2", label: "Read aloud") {
                        readAloud(message.text)
                    }
                    messageAction("doc.on.doc", label: "Copy") {
                        copy(message.text)
                    }
                    messageAction("arrowshape.turn.up.left", label: "Reply") {
                        // A reply in a room is an address: the mention decides who answers.
                        // Answering your own message opens the picker for the same reason.
                        draft = message.isOwner ? "@" + draft : "@\(message.speaker) " + draft
                    }
                    messageAction("face.smiling", label: "React") {
                        reactingSeq = message.seq
                    }
                }
                .padding(.top, 1)
                // The same picker a conversation's reaction menu raises: a small emoji grid
                // anchored to the row that asked for it.
                .popover(isPresented: reactingBinding(for: message),
                         attachmentAnchor: .rect(.bounds),
                         arrowEdge: .bottom) {
                    reactionPicker(for: message)
                        .presentationCompactAdaptation(.popover)
                }

                if let emoji = reactions[reactionKey(for: message)] {
                    Button {
                        setReaction(emoji, for: message)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 15))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Tokens.surface))
                            .overlay(Capsule().strokeBorder(Tokens.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove reaction \(emoji)")
                    .accessibilityHint("Select again to remove this reaction")
                }
            }
        }
    }

    /// Your own words: the accent bubble a conversation puts around what you sent. A bot's answer
    /// only lands here when the caller supplied no markdown renderer.
    private func messageBubble(_ text: String, mine: Bool) -> some View {
        Text(text)
            .font(TypeScale.font(TypeScale.chatBody))
            .foregroundStyle(mine ? Tokens.accentText : Tokens.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(TypeScale.chatLineSpacing)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous)
                    .fill(mine ? Tokens.accentSoft : Tokens.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous)
                    .strokeBorder(mine ? Tokens.borderStrong : Tokens.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous))
    }

    // MARK: Message actions

    /// Read a message out loud.
    ///
    /// On the phone this goes through the same voice the conversation uses — the host's TTS played
    /// through an `.playback` audio session — because a bare `AVSpeechSynthesizer` is silent under
    /// the ringer switch, which is exactly how this button looked broken. The Mac has no
    /// server-side voice, and a desktop has no silent switch, so it speaks locally.
    private func readAloud(_ text: String) {
        if let speak {
            Task {
                do { try await speak(text) } catch { failure = error.localizedDescription }
            }
            return
        }
        #if os(macOS) && canImport(AVFoundation)
        Self.speaker.stopSpeaking(at: .immediate)
        Self.speaker.speak(AVSpeechUtterance(string: text))
        #endif
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// One glyph of the row under a message: dim, small, and a button, not decoration.
    private func messageAction(_ systemName: String, label: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Tokens.textDim)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Reactions live on this device, keyed by room and log position: the host's room log has no
    /// reaction verb, so writing one into the transcript would invent an event that never happened.
    private func reactionKey(for message: RoomMessage) -> String {
        "\(room.id):\(message.seq)"
    }

    private var reactions: [String: String] {
        guard let data = storedReactions.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    private func setReaction(_ emoji: String, for message: RoomMessage) {
        var values = reactions
        let key = reactionKey(for: message)
        values[key] = values[key] == emoji ? nil : emoji
        if let data = try? JSONEncoder().encode(values), let encoded = String(data: data, encoding: .utf8) {
            storedReactions = encoded
        }
    }

    /// One popover per row, driven by which row's glyph was tapped.
    private func reactingBinding(for message: RoomMessage) -> Binding<Bool> {
        Binding(get: { reactingSeq == message.seq },
                set: { open in
                    if open { reactingSeq = message.seq }
                    else if reactingSeq == message.seq { reactingSeq = nil }
                })
    }

    private func reactionPicker(for message: RoomMessage) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 4), count: 3), spacing: 4) {
            ForEach(Self.reactionEmoji, id: \.self) { emoji in
                Button {
                    setReaction(emoji, for: message)
                    reactingSeq = nil
                } label: {
                    Text(emoji)
                        .font(.system(size: 26))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("React with \(emoji)")
                .accessibilityHint("Select again to remove this reaction")
            }
        }
        .padding(8)
        .frame(width: 156)
    }

    /// Typing `@` offers the room's bots, because a mention is the thing that decides who answers.
    ///
    /// The field itself is the design system's `Composer` — the same control a bot's chat uses — so
    /// the two conversations in this app feel like one app: same card, same hint line, same ⏎.
    private var composer: some View {
        VStack(spacing: 0) {
            if !pendingFiles.isEmpty { pendingBar }
            if let query = mentionQuery {
                suggestionList(query)
                Hairline(color: Tokens.border)
            }
            if let failure {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.warning)
                    Text(failure)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Dismiss") { self.failure = nil }
                        .font(TypeScale.font(TypeScale.caption))
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.textDim)
                }
                .padding(.horizontal, Geometry.chatGutter)
                .padding(.bottom, 4)
            }
            Composer(text: $draft,
                     placeholder: "Message the group — @ a bot to pick who answers",
                     isSending: sending,
                     hasAttachments: !pendingFiles.isEmpty,
                     showsMic: false,
                     hint: composerHint,
                     onSend: { Task { await post() } },
                     onAttach: {
                         #if os(iOS)
                         showingAttachOptions = true
                         #else
                         showingImporter = true
                         #endif
                     },
                     onAttachItems: { items in
                         pendingFiles.append(contentsOf: items.map {
                             RoomAttachment(name: $0.name, data: $0.data, isImage: $0.isImage)
                         })
                     })
                .onChange(of: draft) { _, text in mentionQuery = Self.trailingMention(text) }
                // The field is the same `Composer` a bot's chat uses, so it stops at the same
                // gutter — and at the same 8 pt above and below it.
                .padding(.horizontal, Geometry.chatGutter)
                .padding(.top, 8)
                .padding(.bottom, 8)
        }
        .background(Tokens.canvas)
    }

    /// The files waiting to go with the next message.
    private var pendingBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(pendingFiles.enumerated()), id: \.offset) { index, file in
                    HStack(spacing: 5) {
                        Image(systemName: file.isImage ? "photo" : "doc")
                            .font(.system(size: 10))
                        Text(file.name)
                            .font(TypeScale.font(TypeScale.caption))
                            .lineLimit(1)
                        Button {
                            pendingFiles.remove(at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(Tokens.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Tokens.surface)
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, Geometry.chatGutter)
            .padding(.vertical, 6)
        }
    }

    /// Read one picked file into memory, as the bridge wants it.
    private func load(_ url: URL) -> RoomAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        return RoomAttachment(name: url.lastPathComponent, data: data,
                              isImage: type?.conforms(to: .image) ?? false)
    }

    private func suggestionList(_ query: String) -> some View {
        let matches = room.members.filter {
            query.isEmpty || $0.mention.lowercased().hasPrefix(query.lowercased())
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(matches) { member in
                    Button { insert(member.mention) } label: {
                        Text("@\(member.mention)")
                            .font(TypeScale.font(TypeScale.caption, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Tokens.surface)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if matches.isEmpty {
                    Text("no bot in this room matches")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textDim)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// The `@word` being typed at the very end of the draft, if any.
    private static func trailingMention(_ text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let tail = text[text.index(after: at)...]
        guard !tail.contains(" "), !tail.contains("\n") else { return nil }
        return String(tail)
    }

    private func insert(_ handle: String) {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at]) + "@\(handle) "
        mentionQuery = nil
    }

    // MARK: Host

    private func poll() async {
        await refresh(reset: true)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            await refresh(reset: false)
        }
    }

    private func refresh(reset: Bool) async {
        do {
            let page = try await load(room.id, reset ? nil : latestSeq)
            if reset {
                messages = page.messages
            } else if !page.messages.isEmpty {
                let known = Set(messages.map(\.seq))
                messages.append(contentsOf: page.messages.filter { !known.contains($0.seq) })
                messages.sort { $0.seq < $1.seq }
                // A member spoke: the turn the composer was waiting on has produced something.
                if !page.messages.filter({ !$0.isOwner }).isEmpty { sending = false }
                if !page.messages.isEmpty { onActivity?() }
            }
            let previousSeq = latestSeq
            latestSeq = max(latestSeq, page.latestSeq)
            if latestSeq > previousSeq { onLatestSeq?(latestSeq) }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        loading = false
    }

    private func post() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingFiles.isEmpty else { return }
        let files = pendingFiles
        draft = ""
        pendingFiles = []
        mentionQuery = nil
        sending = true
        do {
            try await send(room.id, text, files)
            await refresh(reset: false)
        } catch {
            // Deliberately *not* restored into the field. A slow host accepts the message and then
            // times out the reply, and putting the text back made the composer look like it had
            // ignored the send; the refresh below shows whether it actually landed.
            sending = false
            await refresh(reset: false)
            if !messages.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                            == text && $0.isOwner }) {
                failure = error.localizedDescription
            }
        }
    }
}

// MARK: - Row

/// One group chat in a list: its name, the bots in it as overlapping faces, who spoke last, and when.
///
/// The faces are not decoration — a room's membership is frozen at creation, so the row is the only
/// place that answers "who is in this one?" without opening it.
public struct GroupChatRow: View {
    private let room: RoomSummary
    private let icons: [String: BotIcon]
    /// How many bot messages are waiting in this room, drawn on its faces the way a bot's count
    /// sits on its portrait. Zero draws nothing.
    private let unread: Int

    public init(room: RoomSummary, icons: [String: BotIcon], unread: Int = 0) {
        self.room = room
        self.icons = icons
        self.unread = unread
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Geometry.rosterRowGap) {
            // The room's faces read at the same weight as a bot's single portrait, so a group chat
            // and a bot sit in the list as equals. Unread is the same 8 pt dot a bot row uses —
            // the count lives in the app badge, not in the row.
            faces
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(room.name)
                        .font(TypeScale.font(Tokens.rosterName, weight: unread > 0 ? .semibold : .medium))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let at = room.lastAt ?? room.updatedAt {
                        Text(RelativeTime.stamp(at))
                            .font(TypeScale.font(Tokens.rosterMeta))
                            .foregroundStyle(Tokens.textDim)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    if unread > 0 {
                        Circle()
                            .fill(Tokens.accent)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("unread")
                    }
                }
                HStack(spacing: 4) {
                    if let speaker = room.lastSpeaker {
                        Text(room.lastFromOwner ? "You" : "@\(speaker)")
                            .font(TypeScale.font(Tokens.rosterMeta, weight: .semibold))
                            .foregroundStyle(Tokens.textMuted)
                        Text(speakerLine)
                            .font(TypeScale.font(Tokens.rosterMeta))
                            .foregroundStyle(Tokens.textDim)
                            .lineLimit(1)
                    } else {
                        Text(room.members.map { "@\($0.mention)" }.joined(separator: " "))
                            .font(TypeScale.font(Tokens.rosterMeta))
                            .foregroundStyle(Tokens.textDim)
                            .lineLimit(1)
                    }
                }
                .truncationMode(.tail)
            }
        }
        .contentShape(Rectangle())
    }

    /// `You: sounds good` — the speaker is already a label, so the preview is only the words.
    private var speakerLine: String {
        let text = (room.lastText ?? "").replacingOccurrences(of: "\n", with: " ")
        return text.isEmpty ? "no messages yet" : text
    }

    /// Up to three faces, each tucked under the one before it, sized so the stack reads as one
    /// portrait beside a 38 pt bot face.
    private var faces: some View {
        HStack(spacing: -8) {
            ForEach(Array(room.members.prefix(3))) { member in
                BotIconPortrait(icons[member.profile] ?? BotIcon.default(for: member.profile), size: 30)
                    .overlay(Circle().stroke(Tokens.canvas, lineWidth: 1.5))
            }
            if room.members.count > 3 {
                Text("+\(room.members.count - 3)")
                    .font(TypeScale.font(TypeScale.micro, weight: .semibold))
                    .foregroundStyle(Tokens.textMuted)
                    .padding(.leading, 10)
            }
        }
        .fixedSize()
    }
}
