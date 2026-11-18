import AppKit
import CoreGraphics
import Foundation

/// Physical input pauses a bot that is driving the desktop, and only an explicit resume continues it.
///
/// The event tap is listen-only: it never blocks or rewrites an event, it only notices that a
/// human touched the machine. Hermey's own events carry `ComputerEventTag.herm` in
/// `eventSourceUserData`, so a bot clicking the mouse does not pause itself. The pause is a gate in
/// front of every action in a batch, which is why a batch stops between two actions rather than
/// mid-click — the action in flight is already committed, the next one waits.
@MainActor
final class ComputerTakeover: ObservableObject {
    static let shared = ComputerTakeover()

    /// True from the first physical event until `resume()`.
    @Published private(set) var active = false

    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    /// Start listening. Safe to call repeatedly; a tap that already exists is left alone.
    ///
    /// Creating the tap can fail (Accessibility not granted yet, or the session is switching); the
    /// primitive is then simply absent rather than half-installed, and `start()` may be called again
    /// after the grant.
    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
        let callback: CGEventTapCallBack = { _, _, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let takeover = Unmanaged<ComputerTakeover>.fromOpaque(refcon).takeUnretainedValue()
            if event.getIntegerValueField(.eventSourceUserData) != ComputerEventTag.herm {
                Task { @MainActor in takeover.pause() }
            }
            return Unmanaged.passUnretained(event)
        }
        if let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask),
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) {
            tap = created
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
            if let source = runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: created, enable: true)
        }
    }

    /// Stop listening and release anyone still waiting. Called when computer use is switched off.
    func stop() {
        if let existing = tap {
            CGEvent.tapEnable(tap: existing, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        tap = nil
        runLoopSource = nil
        resume()
    }

    /// A human touched the machine. Every later action in the running batch waits here.
    func pause() {
        active = true
    }

    /// The owner handed control back. Every waiter continues from exactly where it stopped.
    func resume() {
        active = false
        let resumed = waiters
        waiters = []
        resumed.forEach { $0.resume() }
    }

    /// Suspend until `resume()` when a takeover is active, otherwise return immediately.
    func waitWhilePaused() async {
        guard active else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
