import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

// MARK: - Presentation

/// One choice a request offers, in the gateway's own words when it supplies them.
struct ApprovalChoice: Identifiable, Equatable {
    let id: String
    let label: String
}

/// A `ServerRequest`, flattened into what a screen can draw.
///
/// The gateway sends `approval`, `clarify`, `sudo`, `secret`, `vault.code`,
/// `terminal.read`; only the shape of `params` differs. This reads the common keys
/// tolerantly and falls back to pretty-printed params rather than inventing a summary —
/// an approval must show exactly what the host asked, never a paraphrase.
struct PendingRequestPresentation: Equatable {
    let method: String
    let tool: String
    let command: String
    let reason: String?
    let scope: String
    let choices: [ApprovalChoice]

    var isApproval: Bool {
        let lowered = method.lowercased()
        return lowered.contains("approval") || lowered == "sudo" || lowered.contains("terminal.read")
    }

    var headline: String {
        if isApproval { return "Approval needed" }
        return params["question"]?.stringValue ?? "Hermes needs an answer"
    }

    private let params: JSONValue

    init(_ request: ServerRequest) {
        let params = request.params
        self.params = params
        self.method = request.method
        self.tool = params["tool"]?.stringValue
            ?? params["tool_name"]?.stringValue
            ?? params["name"]?.stringValue
            ?? params["kind"]?.stringValue
            ?? request.method
        self.command = params["command"]?.stringValue
            ?? params["cmd"]?.stringValue
            ?? params["prompt"]?.stringValue
            ?? params["path"]?.stringValue
            ?? params["url"]?.stringValue
            ?? PendingRequestPresentation.describe(params)
        self.reason = params["reason"]?.stringValue
            ?? params["why"]?.stringValue
            ?? params["description"]?.stringValue
            ?? params["message"]?.stringValue
        self.scope = params["scope"]?.stringValue ?? "this session"
        self.choices = PendingRequestPresentation.choices(in: params)
    }

    // MARK: Parsing helpers

    private static func choices(in params: JSONValue) -> [ApprovalChoice] {
        guard let raw = params["choices"] ?? params["options"],
              case .array(let items) = raw else { return [] }
        return items.enumerated().compactMap { index, item in
            switch item {
            case .string(let value):
                return ApprovalChoice(id: value, label: value)
            case .object(let object):
                let id = object["value"]?.stringValue
                    ?? object["id"]?.stringValue
                    ?? object["key"]?.stringValue
                    ?? "\(index)"
                let label = object["label"]?.stringValue
                    ?? object["title"]?.stringValue
                    ?? object["text"]?.stringValue
                    ?? id
                return ApprovalChoice(id: id, label: label)
            default:
                return nil
            }
        }
    }

    private static func describe(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else { return "—" }
        return text
    }
}

// MARK: - Inline card

/// What sits in the transcript while a request is open.
struct MobilePendingRequestCard: View {
    @ObservedObject var model: AppModel
    let request: ServerRequest
    var onExpand: (() -> Void)?

    private var presentation: PendingRequestPresentation {
        PendingRequestPresentation(request)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentation.isApproval {
                ApprovalCard(tool: presentation.tool,
                             command: presentation.command,
                             why: presentation.reason,
                             scope: presentation.scope,
                             status: .pending,
                             // The gateway's own `choices` decide which buttons exist
                             // (`fixtures/NOTES.md` §6); the card must not invent an
                             // "Always" the host did not offer.
                             allowsAlways: false) { decision in
                    Haptics.selection()
                    answer(decision)
                }
            } else {
                MobileQuestionCard(presentation: presentation,
                                   onChoose: { choice in
                                       Task { await model.answer(request, choice: choice.id) }
                                   },
                                   onDecline: { Task { await model.decline(request) } })
            }

            if let onExpand {
                Button(action: onExpand) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Open as a sheet")
                            .font(TypeScale.font(TypeScale.label, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Tokens.textDim)
                    .padding(.top, 8)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open this request as a sheet")
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private func answer(_ decision: ApprovalCard.Decision) {
        Task {
            if decision == .denied {
                await model.deny(request)
            } else {
                await model.approve(request)
            }
        }
    }
}

/// The non-approval request: a question with options, or a free-form prompt.
///
/// TODO(design-system): replace with an OpenBotUI `QuestionCard` once one lands; this is
/// the same card shape as ApprovalCard without the warning tint.
struct MobileQuestionCard: View {
    let presentation: PendingRequestPresentation
    let onChoose: (ApprovalChoice) -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.accentText)
                SectionCaption("HERMES ASKS", color: Tokens.accentText)
                Spacer(minLength: 8)
                Text(presentation.method)
                    .font(Tokens.mono)
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
            }

            Text(presentation.headline)
                .font(TypeScale.font(TypeScale.lg, weight: .medium))
                .foregroundStyle(Tokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = presentation.reason, !reason.isEmpty, reason != presentation.headline {
                Text(reason)
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !presentation.choices.isEmpty {
                VStack(spacing: 8) {
                    ForEach(presentation.choices) { choice in
                        OpenBotButton(choice.label, kind: .secondary) { onChoose(choice) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            HStack {
                TextButton("Decline", tone: Tokens.textMuted, action: onDecline)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .cardSurface()
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .strokeBorder(Tokens.accentSoft, lineWidth: 1)
        )
    }
}

// MARK: - Sheet

/// The modal version. Arrives when a request lands, so a phone in a pocket does not
/// silently hold a blocked agent; the inline card stays behind for the record.
struct MobileApprovalSheet: View {
    @ObservedObject var model: AppModel
    let request: ServerRequest?

    @Environment(\.dismiss) private var dismiss
    @State private var pendingDecision: ApprovalCard.Decision?

    private var presentation: PendingRequestPresentation? {
        request.map(PendingRequestPresentation.init)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let presentation {
                    content(presentation)
                } else {
                    handled
                }
            }
            .background(Tokens.canvas)
            .navigationTitle("Approval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Tokens.textMuted)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: model.pendingRequests.count) {
            if model.pendingRequests.isEmpty { dismiss() }
        }
    }

    private func content(_ presentation: PendingRequestPresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(presentation.headline)
                    .font(TypeScale.font(TypeScale.chatBody, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)

                Text("The turn is paused on the host until you answer.")
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(Tokens.textMuted)

                if presentation.isApproval {
                    ApprovalCard(tool: presentation.tool,
                                 command: presentation.command,
                                 why: presentation.reason,
                                 scope: presentation.scope,
                                 status: .pending,
                                 answering: pendingDecision,
                                 allowsAlways: false) { decision in
                        answer(decision)
                    }
                } else {
                    MobileQuestionCard(presentation: presentation,
                                       onChoose: { choice in
                                           guard let request else { return }
                                           Task {
                                               await model.answer(request, choice: choice.id)
                                               dismiss()
                                           }
                                       },
                                       onDecline: {
                                           guard let request else { return }
                                           Task {
                                               await model.decline(request)
                                               dismiss()
                                           }
                                       })
                }

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10))
                    Text("This app can answer approvals. It cannot grant itself new permissions.")
                        .font(TypeScale.font(TypeScale.label))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Tokens.textDim)
                .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var handled: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Tokens.textMuted)
            Text("Nothing is waiting.")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func answer(_ decision: ApprovalCard.Decision) {
        guard let request else { return }
        pendingDecision = decision
        Haptics.selection()
        Task {
            if decision == .denied {
                await model.deny(request)
            } else {
                await model.approve(request)
            }
            pendingDecision = nil
            dismiss()
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Inline approval") {
    let model = AppModel(client: PreviewGatewayClient())
    ScrollView {
        MobilePendingRequestCard(model: model,
                                 request: ServerRequest(id: .int(7),
                                                        method: "approval",
                                                        params: .object([
                                                            "tool": .string("bash"),
                                                            "command": .string("restic backup ~/vault --tag nightly"),
                                                            "reason": .string("Writes a new snapshot to the repo configured for this session."),
                                                        ])),
                                 onExpand: {})
            .padding(16)
    }
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
#endif

#if DEBUG
#Preview("Approval sheet") {
    Tokens.canvas
        .sheet(isPresented: .constant(true)) {
            MobileApprovalSheet(model: AppModel(client: PreviewGatewayClient()),
                                request: ServerRequest(id: .int(8),
                                                       method: "approval",
                                                       params: .object([
                                                           "tool": .string("bash"),
                                                           "command": .string("gh pr merge 41 --squash --delete-branch"),
                                                           "reason": .string("This merges the branch into main and deletes the remote branch."),
                                                       ])))
        }
        .preferredColorScheme(.dark)
}
#endif
