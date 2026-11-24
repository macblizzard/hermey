import HermesAppKit
import HermeyUI
import SwiftUI

/// The menu-bar half of the takeover indicator.
///
/// The icon is the status at a glance: a desktop when a bot may drive the machine, a raised hand
/// when the owner's input has paused it, and a slash when computer use is off.
struct ComputerControlMenuBarLabel: View {
    @ObservedObject private var service = LocalComputerService.shared
    @ObservedObject private var takeover = ComputerTakeover.shared

    var body: some View {
        Image(systemName: service.status == .connected
              ? (takeover.active ? "hand.raised" : "desktopcomputer")
              : "slash.circle")
    }
}

/// What the menu-bar item opens: the one line of status, and the one action that matters.
struct ComputerControlMenu: View {
    @ObservedObject private var service = LocalComputerService.shared
    @ObservedObject private var takeover = ComputerTakeover.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(service.status == .connected
                 ? (takeover.active ? "Bot control paused by your input" : "Bot control active")
                 : "Computer use off")
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textPrimary)

            if takeover.active {
                Button("Resume bot control") {
                    service.resumeAfterTakeover()
                }
                .hermeyFocusQuiet()
            }

            Divider()

            Text("\(service.commandsRun) command(s) this session")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
        }
        .padding(10)
        .frame(width: 240, alignment: .leading)
    }
}
