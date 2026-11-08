import Foundation
import SwiftUI

/// The one card that blocks a turn: what Hermes wants to run, why, and three ways to
/// answer it.
///
/// It is the only surface in the app allowed a gradient — the warning tint that fades
/// into the card. Once answered it collapses to a one-line receipt, so the transcript
/// keeps the record without keeping the weight. Risk is never softened: the command is
/// shown exactly as the host sent it, in mono, selectable.
public struct ApprovalCard: View {
    public enum Decision: String, CaseIterable, Sendable {
        case once
        case always
        case denied

        var actionTitle: String {
            switch self {
            case .once: return "Allow once"
            case .always: return "Always"
            case .denied: return "Deny"
            }
        }

        var receipt: String {
            switch self {
            case .once: return "Allowed once"
            case .always: return "Allowed, and remembered"
            case .denied: return "Denied"
            }
        }
    }

    public enum Status: Equatable {
        case pending
        case answered(Decision)
        case expired
    }

    private let tool: String
    private let command: String
    private let why: String?
    private let scope: String
    private let status: Status
    private let answering: Decision?
    private let allowsAlways: Bool
    private let answeredAt: Date?

    private let onAnswer: ((Decision) -> Void)?

    public init(tool: String,
                command: String,
                why: String? = nil,
                scope: String = "this session",
                status: Status = .pending,
                answering: Decision? = nil,
                allowsAlways: Bool = true,
                answeredAt: Date? = nil,
                onAnswer: ((Decision) -> Void)? = nil) {
        self.tool = tool
        self.command = command
        self.why = why
        self.scope = scope
        self.status = status
        self.answering = answering
        self.allowsAlways = allowsAlways
        self.answeredAt = answeredAt
        self.onAnswer = onAnswer
    }

    public var body: some View {
        Group {
            switch status {
            case .pending:
                pending
            case .answered(let decision):
                receipt(decision)
            case .expired:
                expired
            }
        }
    }

    // MARK: Pending

    private var pending: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.warning)

                SectionCaption("APPROVAL NEEDED", color: Tokens.warning)

                Spacer(minLength: 8)

                Text(tool)
                    .font(Tokens.mono)
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Approval needed for \(tool)")

            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Tokens.textPrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .fill(Tokens.sheetInset)
                )
                .accessibilityLabel("Command: \(command)")

            if let why, !why.isEmpty {
                Text(why)
                    .font(TypeScale.font(TypeScale.sm))
                    .lineSpacing(2)
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            buttons
                .padding(.top, 1)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .fill(
                    LinearGradient(colors: [Tokens.warningSoft, Tokens.surface],
                                   startPoint: .top,
                                   endPoint: .bottom)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .strokeBorder(Tokens.warningSoft, lineWidth: 1)
        )
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            answerButton(.once, kind: .primary)

            if allowsAlways {
                answerButton(.always, kind: .ghost, title: "Always for \(scope)")
            }

            Spacer(minLength: 0)

            answerButton(.denied, kind: .danger)
        }
    }

    private func answerButton(_ decision: Decision,
                              kind: OpenBotButton.Kind,
                              title: String? = nil) -> some View {
        OpenBotButton(title ?? decision.actionTitle,
                      kind: kind,
                      isDisabled: answering != nil,
                      isBusy: answering == decision) {
            Haptics.selection()
            onAnswer?(decision)
        }
        .accessibilityLabel(decision == .denied ? "Deny this request" : (title ?? decision.actionTitle))
    }

    // MARK: Answered

    private func receipt(_ decision: Decision) -> some View {
        HStack(spacing: 8) {
            Image(systemName: decision == .denied ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(decision == .denied ? Tokens.danger : Tokens.success)

            Text(decision.receipt)
                .font(TypeScale.font(TypeScale.sm, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(1)

            Text(command)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Tokens.textDim)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if let answeredAt {
                Text(RelativeTime.detailed(answeredAt))
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textDim)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    // MARK: Expired

    private var expired: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.textDim)

            Text("Expired — the turn moved on")
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textDim)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(tool)
                .font(Tokens.mono)
                .foregroundStyle(Tokens.textDim)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(fill: Tokens.sheet)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Approval · pending") {
    ApprovalCard(tool: "bash",
                 command: "rm -rf ~/jobs/hermey/.build",
                 why: "This deletes the build cache for the hermey package. The source tree is untouched.",
                 scope: "this session",
                 onAnswer: { _ in })
        .frame(width: 460)
        .padding(20)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
}
#endif

#if DEBUG
#Preview("Approval · answered") {
    VStack(spacing: 8) {
        ApprovalCard(tool: "bash",
                     command: "rm -rf ~/jobs/hermey/.build",
                     status: .answered(.once),
                     answeredAt: Date().addingTimeInterval(-600))
        ApprovalCard(tool: "write_file",
                     command: "Sources/OpenBotUI/ToolCard.swift",
                     status: .answered(.denied),
                     answeredAt: Date().addingTimeInterval(-60))
        ApprovalCard(tool: "sudo",
                     command: "systemctl restart hermes-gateway",
                     status: .expired)
    }
    .frame(width: 460)
    .padding(20)
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
#endif
