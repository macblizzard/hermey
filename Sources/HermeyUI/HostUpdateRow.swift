import SwiftUI
import HermesKit

/// The host-update row at the top of the waiting list.
///
/// It is a *row*, not a banner: it lives where the owner already goes to see what is waiting, it is
/// dismissed or acted on in place, and it never appears without a press. Visually distinct from a
/// bot row on purpose — an accent glyph instead of a bot's face, two version numbers instead of a
/// name and a preview, and a filled button instead of nothing. A host update must never be mistaken
/// for one more bot with something to say.
///
/// The words come from `HostUpdate` (in `HermesAppKit`), which is also what the tests read: the
/// view adds no copy of its own, so the Mac and the phone cannot say different things about the
/// same press.
public struct HostUpdateRow: View {
    public var update: HostUpdate
    public var onUpdate: () -> Void
    public var onDismiss: () -> Void

    public init(update: HostUpdate,
                onUpdate: @escaping () -> Void,
                onDismiss: @escaping () -> Void = {}) {
        self.update = update
        self.onUpdate = onUpdate
        self.onDismiss = onDismiss
    }

    /// The glyph's frame. The same pitch as a bot row's face so the list does not jump when this row
    /// arrives or leaves.
    private static var glyphSize: CGFloat {
        #if os(iOS)
        return Geometry.rosterAvatar
        #else
        return 26
        #endif
    }

    private var tint: Color {
        switch update.phase {
        case .available: return Tokens.accent
        case .restarting: return Tokens.accent
        case .updated: return Tokens.success
        case .rolledBack: return Tokens.warning
        case .failed: return Tokens.danger
        default: return Tokens.accent
        }
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            glyph
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(update.headline)
                        .font(TypeScale.font(Tokens.rosterName, weight: .medium))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if update.isSettled {
                        Button {
                            onDismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Tokens.textDim)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss host update")
                        .accessibilityIdentifier("hostUpdate.dismiss")
                        .hermeyFocusQuiet()
                    }
                }
                HStack(spacing: 6) {
                    Text(update.versionLine)
                        .font(TypeScale.font(Tokens.rosterMeta))
                        .foregroundStyle(Tokens.textMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                    if let state = update.stateText {
                        Text(state)
                            .font(TypeScale.font(Tokens.rosterMeta))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .accessibilityIdentifier("hostUpdate.state")
                    }
                    Spacer(minLength: 4)
                }
                if update.showsNotes, let notes = update.notesURL {
                    // Quiet, and only when the host sent one: the notes are a page away from the
                    // decision, not part of it.
                    Link("What's new", destination: notes)
                        .font(TypeScale.font(TypeScale.micro))
                        .foregroundStyle(Tokens.textDim)
                        .accessibilityIdentifier("hostUpdate.notes")
                        .hermeyFocusQuiet()
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 4)
        .padding(.vertical, Self.rowPadding)
        .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hostUpdate.row")
    }

    /// The glyph: an accent circle with the download arrow. Not a bot face — this row is about the
    /// machine, and a face would say "a bot".
    private var glyph: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.16))
            Image(systemName: update.isBusy ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                .font(.system(size: Self.glyphSize * 0.5, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: Self.glyphSize, height: Self.glyphSize)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailing: some View {
        if update.isBusy {
            // The spinner is the whole progress story: the state line says which stage the host is
            // in, and a percentage would be invented (the host reports bytes, not a plan).
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(update.stateText ?? "Updating the host")
        } else if let title = update.buttonTitle {
            Button(title) {
                onUpdate()
            }
            .buttonStyle(.plain)
            .font(TypeScale.font(Tokens.textSM, weight: .semibold))
            .foregroundStyle(Tokens.accentText)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Tokens.accent))
            .contentShape(Capsule())
            .disabled(!update.canStartPress)
            .accessibilityIdentifier("hostUpdate.update")
            .hermeyFocusQuiet()
        }
    }

    /// The height this row occupies in a list, for a caller sizing a sheet around it.
    public static var sheetHeight: CGFloat { minHeight + rowPadding * 2 }

    private static var rowPadding: CGFloat {
        #if os(iOS)
        return 10
        #else
        return 5
        #endif
    }

    /// A settled row is one line taller than a bot row (the version line stays), so the height the
    /// list reserves for it is stated here rather than guessed by the caller.
    private static var minHeight: CGFloat {
        #if os(iOS)
        return 52
        #else
        return 44
        #endif
    }
}

#if DEBUG
#Preview("Host update · available") {
    HostUpdateRow(
        update: HostUpdate(current: "0.3.9", latest: "0.4.0",
                           notesURL: URL(string: "https://github.com/macblizzard/hermey/releases"),
                           phase: .available),
        onUpdate: {})
        .frame(width: 300)
        .background(Tokens.sidebar)
        .preferredColorScheme(.dark)
}

#Preview("Host update · restarting") {
    HostUpdateRow(
        update: HostUpdate(current: "0.3.9", latest: "0.4.0", phase: .restarting),
        onUpdate: {})
        .frame(width: 300)
        .background(Tokens.sidebar)
        .preferredColorScheme(.dark)
}

#Preview("Host update · rolled back") {
    HostUpdateRow(
        update: HostUpdate(current: "0.3.9", latest: "0.4.0", phase: .rolledBack("0.3.9")),
        onUpdate: {})
        .frame(width: 300)
        .background(Tokens.sidebar)
        .preferredColorScheme(.dark)
}
#endif
