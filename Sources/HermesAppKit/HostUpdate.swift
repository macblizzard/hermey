import Foundation
import HermesKit

/// The rules of a press, as a value type, so they can be tested without a socket or a SwiftUI view.
///
/// The important ones:
///
/// * a row exists only when the host says a version is available **and** says it may install it;
/// * nothing is applied by a check — `pressed` is the only door, and only the app's own button
///   leads to it;
/// * a version change that arrives while pressing is the success; the *absence* of one after the
///   deadline is the failure — never a socket error, because the socket is supposed to die.
public struct HostUpdateTracker: Equatable, Sendable {
    /// The row as it should be drawn, or nil for "nothing to say".
    public private(set) var update: HostUpdate?
    /// The version the button was pressed for. Kept while pressing so a check that answers with an
    /// older `latest` (a feed re-cut mid-press) cannot invent a success.
    public private(set) var target: String?
    public private(set) var pressedAt: Date?
    /// True once a press has resolved, so a later check cannot replace "Updated to 0.4.0" with a
    /// fresh "Update" row for the same version.
    public private(set) var settled = false

    /// How long a press may take before the row says so. Three minutes: a 15 MB download, a copy and
    /// two service restarts, with room for a slow link.
    public static let deadline: TimeInterval = 180

    public init() {}

    /// `GET /v1/update` answered.
    ///
    /// - Parameters:
    ///   - socketDropped: the relay is not connected. During a press that is the restart itself.
    public mutating func checked(_ status: HostUpdateStatus, at now: Date, socketDropped: Bool) {
        guard let pressedAt, let target else {
            // Not pressing. The row is the host's answer and nothing else.
            guard !settled else { return }
            // `hasNewerRelease`, not `available`: a feed still behind the running build (latest
            // 0.4.0 beside a host on 0.8.14) answers `available: false`, and if it ever answered
            // true the row must still not offer the older version as an update.
            guard status.available, status.canSelfUpdate, status.hasNewerRelease,
                  let latest = status.latest else {
                update = nil
                return
            }
            update = HostUpdate(current: status.current,
                                latest: latest,
                                notesURL: status.notesURL,
                                phase: .available,
                                canUpdate: true)
            return
        }

        // A press is open. Success first: the host is running the version that was asked for, or it
        // has told us it put the previous one back.
        if let record = status.lastUpdate, record.isRolledBack, status.current == record.previous {
            settle(.rolledBack(status.current), current: status.current, latest: target,
                   notesURL: status.notesURL)
            return
        }
        if status.current == target {
            settle(.updated(status.current), current: target, latest: target,
                   notesURL: status.notesURL)
            return
        }
        // Still the old build: report the stage the host reports, and nothing it has not said.
        let nextPhase: HostUpdate.Phase?
        switch status.progress ?? "" {
        case "downloading": nextPhase = .downloading
        case "verifying": nextPhase = .verifying
        case "installing": nextPhase = .restarting
        default: nextPhase = socketDropped ? .restarting : nil
        }
        if let nextPhase {
            update = HostUpdate(current: status.current, latest: target,
                                notesURL: status.notesURL, phase: nextPhase)
        }
        if now.timeIntervalSince(pressedAt) > Self.deadline {
            settle(.failed("the host did not come back"), current: status.current, latest: target,
                   notesURL: status.notesURL)
        }
    }

    /// The press was accepted: 202 and a target. The row leaves "available" at once — the button is
    /// gone before the first byte arrives, so a second press is impossible.
    public mutating func pressed(_ ack: HostUpdateAck, at now: Date) {
        guard !settled else { return }
        target = ack.target
        pressedAt = now
        let current = update?.current ?? ""
        update = HostUpdate(current: current, latest: ack.target,
                            notesURL: update?.notesURL, phase: .downloading)
    }

    /// The host refused the press (403/409/503), or the app could not reach it. This is a failure of
    /// the *request*, not of the update — the host is still on its old build and saying so.
    public mutating func refused(_ reason: String) {
        guard let current = update?.current, let target = update?.latest else {
            update = nil
            return
        }
        settle(.failed(reason), current: current, latest: target, notesURL: update?.notesURL)
    }

    /// No host, no route, or a check that could not be answered before a press: nothing is drawn and
    /// nothing is said. Silence is the correct answer for an old host.
    public mutating func silent() {
        guard pressedAt == nil, !settled else { return }
        update = nil
    }

    /// The poll gave up without an answer — the host never came back at all, so no check could
    /// report it. Only ever settles a press that is still open.
    public mutating func timedOut() {
        guard pressedAt != nil, !settled else { return }
        let current = update?.current ?? ""
        let latest = target ?? update?.latest ?? ""
        settle(.failed("the host did not come back"), current: current, latest: latest,
               notesURL: update?.notesURL)
    }

    /// The owner dismissed a settled row.
    public mutating func dismiss() {
        guard settled else { return }
        update = nil
        settled = false
        target = nil
        pressedAt = nil
    }

    private mutating func settle(_ phase: HostUpdate.Phase,
                                 current: String,
                                 latest: String,
                                 notesURL: URL?) {
        update = HostUpdate(current: current, latest: latest, notesURL: notesURL, phase: phase)
        settled = true
        pressedAt = nil
    }
}
