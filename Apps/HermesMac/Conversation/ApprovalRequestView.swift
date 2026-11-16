import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// A request the gateway is blocked on, drawn with the card that fits its method.
///
/// The approval family is one card (`ApprovalCard`); `clarify` needs choices, so it has its
/// own; anything this build does not know is shown raw with a Decline, because a request
/// nobody can render would otherwise hold the agent until it times out
/// (`fixtures/NOTES.md` §2 lists the methods the host may send).
struct ApprovalRequestView: View {
    let request: ServerRequest
    @ObservedObject var store: WorkspaceStore

    private var presentation: ServerRequestPresentation {
        ServerRequestPresentation(request)
    }

    var body: some View {
        Group {
            switch presentation.method {
            case "clarify":
                MacClarifyCard(request: request, presentation: presentation, store: store)
            case "approval", "sudo", "secret":
                approvalCard
            default:
                MacUnknownRequestCard(request: request, presentation: presentation, store: store)
            }
        }
    }

    /// Approval, sudo and secret all resolve to "may this run?" — one card, one pair of answers.
    ///
    /// There *is* a verb for remembering: the answer carries `choice`, and `always` is the token the
    /// host records in its own allow-list (the CLI's `[a]lways` sends the same one). The gateway only
    /// advertises it in `choices` for a request that may be answered permanently, so the button
    /// follows the offer rather than assuming it.
    private var approvalCard: some View {
        ApprovalCard(tool: presentation.tool,
                     command: presentation.command,
                     why: presentation.rationale,
                     scope: presentation.scope,
                     allowsAlways: offersAlways,
                     onAnswer: { decision in
                         switch decision {
                         case .always:
                             store.approve(request, remembering: true)
                         case .once:
                             store.approve(request)
                         case .denied:
                             store.deny(request)
                         }
                     })
    }

    /// Whether the host offered a permanent answer for this request.
    private var offersAlways: Bool {
        guard case .array(let items)? = request.params["choices"] else { return false }
        return items.contains { $0.stringValue == "always" }
    }
}

// MARK: - Previews

private struct ApprovalRequestViewPreview: View {
    @StateObject private var store = PreviewWorkspace.store(.approval)

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(store.model.pendingRequests) { request in
                    ApprovalRequestView(request: request, store: store)
                }
                ApprovalRequestView(
                    request: ServerRequest(id: .string("srq-9"),
                                           method: "clarify",
                                           params: .object([
                                            "question": .string("Which vault should I back up first?"),
                                            "choices": .array([.string("personal"), .string("work"), .string("both")]),
                                           ])),
                    store: store)
                ApprovalRequestView(
                    request: ServerRequest(id: .string("srq-10"),
                                           method: "theme.pick",
                                           params: .object(["palette": .string("dark")])),
                    store: store)
            }
            .padding(20)
            .frame(width: Geometry.conversationMeasure)
        }
        .background(Tokens.canvas)
        .task { await store.attachPreviewHost() }
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Approval requests") {
    ApprovalRequestViewPreview()
}
#endif
