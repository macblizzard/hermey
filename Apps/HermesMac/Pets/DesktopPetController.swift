import AppKit
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
    var occlusionObserver: NSObjectProtocol?

    init(bot: Bot, panel: DesktopPetPanel, hitView: PetHitTestView, model: PetModel) {
        self.bot = bot
        self.panel = panel
        self.hitView = hitView
        self.model = model
    }

    /// The face changed in the picker: redraw it and re-derive where its alpha is.
    func updateFace(_ face: String?) {
        model.face = face
        hitView.iconMask = PetIconMask(identity: bot.id,
                                       face: face,
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
    private var dragOrigins: [String: NSPoint] = [:]
    private var cursorTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Lifecycle

    /// Called once, from the window root. Idempotent: re-appearing a window must not double the pets.
    func attach(store: WorkspaceStore) {
        guard self.store !== store else { return }
        self.store = store
        installObservers()
        sync()
    }

    /// Reconcile the pets on screen with the bots this Mac knows and the switches it stores.
    ///
    /// Called at launch, when the roster changes, when a face changes, and when a bot is turned off
    /// on the host. It is the only place that decides whether a window should exist.
    func sync() {
        guard let store else { return }
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
            show(bot, face: store.botFaces[bot.id]?.raw)
        }

        // A face can change in the icon picker while its pet is on screen.
        for bot in bots {
            pets[bot.id]?.updateFace(store.botFaces[bot.id]?.raw)
        }
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
            show(bot, face: store?.botFaces[bot.id]?.raw)
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

    private func show(_ bot: Bot, face: String?) {
        guard pets[bot.id] == nil else { return }
        let iconSide = CGFloat(PetGeometry.iconSide)
        let windowSide = CGFloat(PetGeometry.windowSide(icon: PetGeometry.iconSide))
        let inset = CGFloat(PetGeometry.motionMargin)
        let origin = placement(for: bot, side: windowSide)

        let model = PetModel(botID: bot.id, botName: bot.displayName, face: face)
        let hosting = NSHostingView(rootView: PetView(
            pet: model,
            onOpen: { [weak self] in self?.openBalloon(botID: bot.id) },
            onDrag: { [weak self] translation, ended in
                self?.drag(botID: bot.id, translation: translation, ended: ended)
            },
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
        hitView.iconMask = PetIconMask(identity: bot.id, face: face, side: iconSide)
        hitView.addSubview(hosting)

        let panel = DesktopPetPanel(side: windowSide)
        panel.contentView = hitView
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
        panel.orderFrontRegardless()

        let instance = PetInstance(bot: bot, panel: panel, hitView: hitView, model: model)
        pets[bot.id] = instance
        observeOcclusion(botID: bot.id)
        startCursorWatch()
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
        dragOrigins[botID] = nil
        pet.panel.orderOut(nil)
        pet.panel.close()

        if writesSetting { PetSettings.setEnabled(false, for: botID) }
        if forgetPosition { PetSettings.setPosition(nil, for: botID) }
        if pets.isEmpty { stopCursorWatch() }

        ClientLog.note("pet closed: \(botID) — \(reason)", category: "pets")
    }

    // MARK: - Dragging

    private func drag(botID: String, translation: CGSize, ended: Bool) {
        guard let pet = pets[botID] else { return }
        if dragOrigins[botID] == nil { dragOrigins[botID] = pet.panel.frame.origin }
        guard let origin = dragOrigins[botID] else { return }

        // SwiftUI's y grows downward; the window server's grows up.
        let proposed = NSPoint(x: origin.x + translation.width, y: origin.y - translation.height)
        let side = pet.panel.frame.width
        let centre = NSPoint(x: proposed.x + side / 2, y: proposed.y + side / 2)
        let screen = screen(containing: centre)
            ?? NSScreen.screens.first(where: { $0.frame.intersects(pet.panel.frame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let clamped = PetGeometry.clamp(
            PetPlacement(x: proposed.x, y: proposed.y, screenID: screenID(screen)),
            side: side,
            to: rect(screen.visibleFrame))
        pet.panel.setFrameOrigin(NSPoint(x: clamped.x, y: clamped.y))

        if ended {
            PetSettings.setPosition(clamped, for: botID)
            dragOrigins[botID] = nil
            ClientLog.note("pet moved: \(botID) to \(clamped.encoded)", category: "pets")
        }
    }

    // MARK: - Balloon

    private func openBalloon(botID: String) {
        guard let pet = pets[botID] else { return }
        if let existing = pet.balloon {
            existing.present()
            return
        }
        let store = self.store
        let model = PetBalloonModel(botID: botID) { question in
            guard let store else { throw BotAskError.unreachable }
            return try await store.model.askBot(profile: botID,
                                                question: question,
                                                from: BotAsk.fromDesktopPet)
        }
        let window = PetBalloonWindow(model: model,
                                      botName: pet.bot.displayName,
                                      anchor: { [weak pet] in
                                          guard let pet else { return nil }
                                          return pet.panel.frame.insetBy(dx: pet.hitView.iconInset,
                                                                         dy: pet.hitView.iconInset)
                                      })
        model.onDismiss = { [weak self] in self?.dismissBalloon(botID: botID) }
        model.onAnswer = { [weak pet] in pet?.model.celebrate() }
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
        guard !pets.isEmpty, dragOrigins.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        for pet in pets.values {
            guard pet.panel.isVisible else { continue }
            let iconRect = pet.panel.frame.insetBy(dx: pet.hitView.iconInset,
                                                   dy: pet.hitView.iconInset)
            let local = CGPoint(x: mouse.x - iconRect.minX, y: iconRect.maxY - mouse.y)
            let overIcon = iconRect.contains(mouse) && pet.hitView.iconMask?.hasInk(at: local) == true
            if pet.panel.ignoresMouseEvents == overIcon {
                pet.panel.ignoresMouseEvents = !overIcon
            }
        }
    }
}
