import AppKit
import Combine
import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// One pet: its window, its content host, and the balloon it can open.
@MainActor
private final class PetInstance {
    let bot: Bot
    let panel: DesktopPetPanel
    let hitView: PetHitTestView
    let model: PetModel
    var balloon: PetBalloonWindow?
    /// The pet's conversation, kept for as long as the pet is: the balloon window comes and goes, and
    /// the last exchange has to survive it. In memory only — a desktop pet's transcript is not a
    /// document, and nothing about it belongs in `UserDefaults`.
    var balloonModel: PetBalloonModel?
    var occlusionObserver: NSObjectProtocol?

    init(bot: Bot, panel: DesktopPetPanel, hitView: PetHitTestView, model: PetModel) {
        self.bot = bot
        self.panel = panel
        self.hitView = hitView
        self.model = model
    }

    /// The face changed in the picker: redraw it and re-derive where its alpha is. A bot with a
    /// generated avatar is redrawn from its definition, and its hit area is the outline the
    /// definition draws rather than a picture's pixels.
    func updateFace(_ face: String?, avatar: BotAvatarDocument? = nil, state: OpenBotAvatarState = .idle) {
        model.face = face
        model.avatar = avatar
        model.state = state
        hitView.iconMask = PetIconMask(identity: bot.id,
                                       face: face,
                                       avatar: avatar,
                                       side: CGFloat(PetGeometry.iconSide))
    }
}

/// Owns one floating panel per enabled bot.
///
/// The design's list, in order: restore at launch, close a pet whose bot disappeared or was switched
/// off, clamp positions when the screens change, stop animating occluded windows, and disappear with
/// the app. Nothing is created here that the settings toggle cannot undo — the toggle, Close pet and
/// this controller all write the same two keys through `PetSettings`.
@MainActor
final class DesktopPetController: ObservableObject {
    static let shared = DesktopPetController()

    private weak var store: WorkspaceStore?
    private var pets: [String: PetInstance] = [:]
    /// Pets whose window is being dragged right now. The cursor watch stands down for those: the
    /// window is under the pointer and moving, so re-deciding click-through mid-drag would flicker.
    private var dragging: Set<String> = []
    private var cursorTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// The `AppModel.objectWillChange` subscription behind the unread badges, and the model it was
    /// made for: a re-pair builds a fresh model, and a watch on the old one would go quiet.
    private var unreadWatch: AnyCancellable?
    private var watchedModel: ObjectIdentifier?

    private init() {}

    // MARK: - Lifecycle

    /// Called once, from the window root. Idempotent: re-appearing a window must not double the pets.
    func attach(store: WorkspaceStore) {
        guard self.store !== store else { return }
        self.store = store
        installObservers()
        watchUnread()
        sync()
    }

    /// Reconcile the pets on screen with the bots this Mac knows and the switches it stores.
    ///
    /// Called at launch, when the roster changes, when a face changes, and when a bot is turned off
    /// on the host. It is the only place that decides whether a window should exist.
    func sync() {
        guard let store else { return }
        // Cheap and identity-guarded: called on every roster change, and only re-subscribes when the
        // store replaced its model (a re-pair).
        watchUnread()
        let bots = store.model.bots
        let present = Set(bots.map(\.id))
        let disabled = store.model.disabledBots

        for botID in Array(pets.keys) {
            let gone = !present.contains(botID)
            let turnedOff = disabled.contains(botID)
            guard gone || turnedOff || !PetSettings.isEnabled(botID) else { continue }
            close(botID,
                  reason: gone ? "bot removed" : turnedOff ? "bot turned off" : "switched off",
                  writesSetting: gone || turnedOff,
                  forgetPosition: gone)
        }

        for bot in bots where PetSettings.isEnabled(bot.id) && pets[bot.id] == nil {
            show(bot, face: store.botFaces[bot.id]?.raw, avatar: store.botAvatars[bot.id])
        }

        // A face can change in the icon picker while its pet is on screen.
        for bot in bots {
            pets[bot.id]?.updateFace(store.botFaces[bot.id]?.raw,
                                 avatar: store.botAvatars[bot.id],
                                 state: OpenBotAvatarState(activity: store.activity(for: bot.id)))
        }

        // A pet that appears while its bot already has something waiting wears the badge at once,
        // and takes the count as its baseline: no hop for a reply that predates the window.
        refreshUnread()
    }

    /// The app is going away: close the windows without touching the switches, so the pets come back
    /// at the next launch exactly as they are now.
    func shutdown() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        for botID in Array(pets.keys) {
            close(botID, reason: "app quit", writesSetting: false, forgetPosition: false)
        }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        unreadWatch = nil
        watchedModel = nil
        ClientLog.note("pets stopped for quit", category: "pets")
    }

    // MARK: - What the settings sheet calls

    func isEnabled(_ botID: String) -> Bool {
        PetSettings.isEnabled(botID)
    }

    /// The toggle. Writes the key the controller itself reads, then makes the window match.
    func setEnabled(_ enabled: Bool, for bot: Bot) {
        PetSettings.setEnabled(enabled, for: bot.id)
        if enabled {
            guard pets[bot.id] == nil else { return }
            show(bot, face: store?.botFaces[bot.id]?.raw,
             avatar: store?.botAvatars[bot.id])
            ClientLog.note("pet enabled: \(bot.id)", category: "pets")
        } else if pets[bot.id] != nil {
            close(bot.id, reason: "switched off in settings",
                  writesSetting: false, forgetPosition: false)
        }
    }

    /// "Bring it here": on the screen the pointer is on, centred, switched on if it was off.
    func bringHere(_ bot: Bot) {
        if !PetSettings.isEnabled(bot.id) { setEnabled(true, for: bot) }
        guard let pet = pets[bot.id], let screen = pointerScreen() else { return }
        let placement = PetGeometry.centre(in: rect(screen.visibleFrame),
                                           screenID: screenID(screen),
                                           side: pet.panel.frame.width)
        pet.panel.setFrameOrigin(NSPoint(x: placement.x, y: placement.y))
        pet.panel.orderFrontRegardless()
        PetSettings.setPosition(placement, for: bot.id)
        refreshPassThrough()
        ClientLog.note("pet brought here: \(bot.id) on screen \(placement.screenID)", category: "pets")
    }

    // MARK: - Showing and closing

    private func show(_ bot: Bot, face: String?, avatar: BotAvatarDocument?) {
        guard pets[bot.id] == nil else { return }
        let iconSide = CGFloat(PetGeometry.iconSide)
        let windowSide = CGFloat(PetGeometry.windowSide(icon: PetGeometry.iconSide))
        let inset = CGFloat(PetGeometry.motionMargin)
        let origin = placement(for: bot, side: windowSide)

        let model = PetModel(botID: bot.id, botName: bot.displayName, face: face, avatar: avatar)
        let hosting = NSHostingView(rootView: PetView(
            pet: model,
            onClose: { [weak self] in self?.userClosed(botID: bot.id) }
        ))
        // The icon sits inside a clear ring, so a hop has somewhere to go instead of being clipped
        // by its own window.
        hosting.frame = NSRect(x: inset, y: inset, width: iconSide, height: iconSide)
        hosting.autoresizingMask = [.width, .height]

        let hitView = PetHitTestView(frame: NSRect(x: 0, y: 0, width: windowSide, height: windowSide))
        hitView.autoresizingMask = [.width, .height]
        hitView.wantsLayer = true
        hitView.layer?.backgroundColor = NSColor.clear.cgColor
        hitView.iconInset = inset
        hitView.iconMask = PetIconMask(identity: bot.id, face: face, avatar: avatar, side: iconSide)
        hitView.addSubview(hosting)

        let panel = DesktopPetPanel(side: windowSide)
        panel.contentView = hitView
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
        // Dragging and clicking are the panel's own AppKit events: a drag moves the window on the
        // event's turn (no gesture, no layout pass, no animation), and a release that never moved is
        // the click that opens the balloon. The controller only supplies the pet's rules.
        panel.onDragBegan = { [weak self] in self?.dragBegan(botID: bot.id) }
        panel.onMoved = { [weak self] origin in self?.dragEnded(botID: bot.id, at: origin) }
        panel.clampOrigin = { [weak self] proposed in
            self?.clampOrigin(botID: bot.id, proposed: proposed) ?? proposed
        }
        panel.onClick = { [weak self] in self?.clicked(botID: bot.id) }
        panel.orderFrontRegardless()

        let instance = PetInstance(bot: bot, panel: panel, hitView: hitView, model: model)
        pets[bot.id] = instance
        observeOcclusion(botID: bot.id)
        startCursorWatch()
        // Whatever is already waiting shows on the pet from its first frame.
        refreshUnread()
        ClientLog.note("pet shown: \(bot.id) at \(origin.encoded)", category: "pets")
    }

    /// The pet's own menu. Closing switches the bot's pet setting off *and* forgets the position, so
    /// the settings toggle is the way back and it comes back centred.
    private func userClosed(botID: String) {
        close(botID, reason: "closed from its own menu", writesSetting: true, forgetPosition: true)
    }

    private func close(_ botID: String, reason: String,
                       writesSetting: Bool, forgetPosition: Bool) {
        guard let pet = pets.removeValue(forKey: botID) else { return }
        pet.balloon?.close()
        pet.balloon = nil
        if let observer = pet.occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        dragging.remove(botID)
        pet.panel.orderOut(nil)
        pet.panel.close()

        if writesSetting { PetSettings.setEnabled(false, for: botID) }
        if forgetPosition { PetSettings.setPosition(nil, for: botID) }
        if pets.isEmpty { stopCursorWatch() }

        ClientLog.note("pet closed: \(botID) — \(reason)", category: "pets")
    }

    // MARK: - Dragging

    /// The pointer is moving the pet: stand the cursor watch down until it lets go.
    private func dragBegan(botID: String) {
        dragging.insert(botID)
    }

    /// Where the pet may sit, for one proposed origin. `PetGeometry.clamp` is the rule, and this is
    /// the only place the window asks for it mid-drag — the arithmetic is a few subtractions, so it
    /// costs nothing to run on every drag event.
    private func clampOrigin(botID: String, proposed: NSPoint) -> NSPoint {
        guard let pet = pets[botID] else { return proposed }
        let side = pet.panel.frame.width
        let centre = NSPoint(x: proposed.x + side / 2, y: proposed.y + side / 2)
        let screen = screen(containing: centre)
            ?? NSScreen.screens.first(where: { $0.frame.intersects(pet.panel.frame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return proposed }
        let clamped = PetGeometry.clamp(
            PetPlacement(x: proposed.x, y: proposed.y, screenID: screenID(screen)),
            side: side,
            to: rect(screen.visibleFrame))
        return NSPoint(x: clamped.x, y: clamped.y)
    }

    /// The drag ended: the pet stays where the pointer left it, and that is what is saved.
    private func dragEnded(botID: String, at origin: NSPoint) {
        dragging.remove(botID)
        guard let pet = pets[botID] else { return }
        let side = pet.panel.frame.width
        let centre = NSPoint(x: origin.x + side / 2, y: origin.y + side / 2)
        let screen = screen(containing: centre)
            ?? NSScreen.screens.first(where: { $0.frame.intersects(pet.panel.frame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let placement = PetGeometry.clamp(
            PetPlacement(x: origin.x, y: origin.y, screenID: screenID(screen)),
            side: side,
            to: rect(screen.visibleFrame))
        pet.panel.setFrameOrigin(NSPoint(x: placement.x, y: placement.y))
        PetSettings.setPosition(placement, for: botID)
        ClientLog.note("pet moved: \(botID) to \(placement.encoded)", category: "pets")
    }

    /// A release that never moved: the pet answers it, then the balloon opens.
    ///
    /// The reaction is the view's (`pet.taps`); it is committed here, before `openBalloon`, so the
    /// pet is hopping while the bubble appears rather than a moment after it.
    private func clicked(botID: String) {
        guard let pet = pets[botID] else { return }
        pet.model.tap()
        openBalloon(botID: botID)
    }

    // MARK: - Balloon

    private func openBalloon(botID: String) {
        guard let pet = pets[botID] else { return }
        // The bubble is the reading: the badge goes, and the app's own dot for this bot with it, on
        // the same rule the conversation uses. Before the early return, so a second click that only
        // re-presents the window still counts.
        clearUnread(for: botID)
        if let existing = pet.balloon {
            existing.present()
            return
        }
        let store = self.store
        // The model outlives the window: the pet keeps its last exchange for as long as it is on the
        // screen, so a dismissal followed by a click shows the answer again instead of an empty box.
        let model = pet.balloonModel ?? PetBalloonModel(botID: botID) { question in
            guard let store else { throw BotAskError.unreachable }
            return try await store.model.askBot(profile: botID,
                                                question: question,
                                                from: BotAsk.fromDesktopPet)
        }
        if pet.balloonModel == nil {
            model.onDismiss = { [weak self] in self?.dismissBalloon(botID: botID) }
            model.onAnswer = { [weak pet] in pet?.model.celebrate() }
            pet.balloonModel = model
        }
        let window = PetBalloonWindow(model: model,
                                      botName: pet.bot.displayName,
                                      anchor: { [weak pet] in
                                          guard let pet else { return nil }
                                          return pet.panel.frame.insetBy(dx: pet.hitView.iconInset,
                                                                         dy: pet.hitView.iconInset)
                                      })
        window.isOwnerWindow = { [weak pet] candidate in candidate === pet?.panel }
        window.onClose = { [weak self] in self?.pets[botID]?.balloon = nil }
        pet.balloon = window
        window.present()
        ClientLog.note("pet \(botID): balloon opened", category: "pets")
    }

    private func dismissBalloon(botID: String) {
        guard let window = pets[botID]?.balloon else { return }
        pets[botID]?.balloon = nil
        window.close()
        ClientLog.note("pet \(botID): balloon closed", category: "pets")
    }

    // MARK: - Unread

    /// Follow the model's own counters instead of inventing a notification system beside it.
    ///
    /// `AppModel` already owns "how many of this bot's turns are waiting" — the number the bot list
    /// and the Dock tile show — and `markBotRead` is already how a bot stops being unread. The pet's
    /// badge is that number, shown; a second counter here would be a second truth.
    ///
    /// `objectWillChange` is sent *before* the mutation lands, so the reading is deferred to the
    /// main actor's next turn, when the new counts are in place. The debounce is for streaming: the
    /// model publishes on every delta of an answer, and the badge only needs the count once the
    /// burst has settled.
    private func watchUnread() {
        guard let store else { return }
        let identity = ObjectIdentifier(store.model)
        guard watchedModel != identity else { return }
        watchedModel = identity
        unreadWatch = store.model.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshUnread() }
            }
        refreshUnread()
    }

    /// Give every pet the count its bot is owed, and hop the ones that gained one while the window
    /// was away.
    ///
    /// The window's state is read once for the pass: it cannot change mid-loop, and asking per pet
    /// would be the same answer N times.
    private func refreshUnread() {
        guard let store else { return }
        let model = store.model
        let away = PetWindowPresence.isAway()
        for (botID, pet) in pets {
            // A balloon already open on this bot is showing its newest exchange: the app's count can
            // still grow behind it (the pet's own ask lands as a message too), and hopping at the
            // answer it is displaying would be the pet telling him what he is reading.
            let count = pet.balloon == nil ? Self.unreadCount(botID: botID, in: model) : 0
            // The pose follows the bot's actual state — the same accessor the list and the header
            // read, so the desktop pet cannot say `working` while the row says `idle`.
            pet.model.state = OpenBotAvatarState(activity: store.activity(for: botID))
            // The hit view draws nothing, but it has to know: the dot sits on a corner the ink may
            // not cover, and a badge the window passes clicks through is not a target.
            pet.hitView.hasBadge = count > 0
            if pet.model.setUnread(count, hopWhenAway: away) {
                ClientLog.note("pet \(botID): hopped — \(count) waiting with the window away",
                               category: "pets")
            }
        }
    }

    /// What the badge shows. A bot marked unread without a count still has one turn waiting: the
    /// app treats the two keys as one fact (`hasUnread`), and so does this.
    private static func unreadCount(botID: String, in model: AppModel) -> Int {
        let count = model.unreadCounts[botID] ?? 0
        if count > 0 { return count }
        return model.unreadBots.contains(botID) ? 1 : 0
    }

    /// The badge cleared from the pet's own side: through the app's rule, never a copy of it.
    ///
    /// Opening the balloon is reading that bot's newest reply, so the bot list's dot goes at the
    /// same time as the pet's — one fact, cleared once.
    private func clearUnread(for botID: String) {
        store?.model.markBotRead(botID)
        pets[botID]?.hitView.hasBadge = false
        pets[botID]?.model.setUnread(0, hopWhenAway: false)
    }

    // MARK: - Screens

    private func installObservers() {
        let centre = NotificationCenter.default
        observers.append(centre.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.clampToScreens() }
        })
        observers.append(centre.addObserver(forName: NSApplication.willTerminateNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.shutdown() }
        })
    }

    /// A display was unplugged or its resolution changed: bring every pet back onto a visible frame.
    private func clampToScreens() {
        for (botID, pet) in pets {
            let frame = pet.panel.frame
            guard let screen = screen(containing: NSPoint(x: frame.midX, y: frame.midY))
                    ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })
                    ?? NSScreen.main
                    ?? NSScreen.screens.first
            else { continue }
            let clamped = PetGeometry.clamp(
                PetPlacement(x: frame.minX, y: frame.minY, screenID: screenID(screen)),
                side: frame.width,
                to: rect(screen.visibleFrame))
            guard clamped.x != frame.minX || clamped.y != frame.minY else { continue }
            pet.panel.setFrameOrigin(NSPoint(x: clamped.x, y: clamped.y))
            PetSettings.setPosition(clamped, for: botID)
            ClientLog.note("pet clamped after a screen change: \(botID) at \(clamped.encoded)",
                           category: "pets")
        }
        refreshPassThrough()
    }

    /// The saved position, clamped into the display it names — or the centre of the main display for
    /// a pet that has never been placed.
    private func placement(for bot: Bot, side: CGFloat) -> PetPlacement {
        if let saved = PetSettings.position(bot.id) {
            let target = NSScreen.screens.first { screenID($0) == saved.screenID }
                ?? NSScreen.main
                ?? NSScreen.screens.first
            guard let target else { return saved }
            let clamped = PetGeometry.clamp(saved, side: side, to: rect(target.visibleFrame))
            // Remember the clamp: the next launch should not repeat this correction.
            if clamped.x != saved.x || clamped.y != saved.y || clamped.screenID != screenID(target) {
                PetSettings.setPosition(PetPlacement(x: clamped.x, y: clamped.y,
                                                     screenID: screenID(target)),
                                        for: bot.id)
            }
            return PetPlacement(x: clamped.x, y: clamped.y, screenID: screenID(target))
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let centred = screen.map {
            PetGeometry.centre(in: rect($0.visibleFrame), screenID: screenID($0), side: side)
        } ?? PetPlacement(x: 120, y: 120, screenID: "0")
        PetSettings.setPosition(centred, for: bot.id)
        return centred
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func pointerScreen() -> NSScreen? {
        screen(containing: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The display's own id (`NSScreenNumber`), stable across launches for the same display.
    private func screenID(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.stringValue ?? screen.localizedName
    }

    private func rect(_ frame: NSRect) -> PetRect {
        PetRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }

    // MARK: - Occlusion

    /// An occluded panel has no one looking at it, so its idle loop sleeps. The observer is per
    /// panel: one stuck pet cannot freeze the rest.
    private func observeOcclusion(botID: String) {
        guard let pet = pets[botID] else { return }
        pet.occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: pet.panel,
            queue: .main
        ) { [weak pet] _ in
            Task { @MainActor in
                guard let pet else { return }
                let visible = pet.panel.occlusionState.contains(.visible)
                if pet.model.isVisible != visible { pet.model.isVisible = visible }
            }
        }
    }

    // MARK: - Click-through

    /// `hitTest` says where the icon is; this makes the window server agree.
    ///
    /// A pixel-transparent borderless window still receives the click on macOS — declining the hit
    /// only stops a *view* from handling it, not the window from swallowing it. So the cursor's
    /// position is sampled (no accessibility permission is needed for `NSEvent.mouseLocation`) and
    /// the panel ignores mouse events everywhere the icon has no ink. Over the icon it takes them,
    /// which is what makes the pet draggable and clickable.
    private func startCursorWatch() {
        guard cursorTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPassThrough() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    private func stopCursorWatch() {
        cursorTimer?.invalidate()
        cursorTimer = nil
    }

    private func refreshPassThrough() {
        guard !pets.isEmpty, dragging.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        for pet in pets.values {
            guard pet.panel.isVisible else { continue }
            let iconRect = pet.panel.frame.insetBy(dx: pet.hitView.iconInset,
                                                   dy: pet.hitView.iconInset)
            let local = CGPoint(x: mouse.x - iconRect.minX, y: iconRect.maxY - mouse.y)
            // The same shape the view answers: the icon's ink and, when it is showing, its badge.
            let overIcon = iconRect.contains(mouse) && pet.hitView.hasTarget(at: local)
            if pet.panel.ignoresMouseEvents == overIcon {
                pet.panel.ignoresMouseEvents = !overIcon
            }
        }
    }
}
