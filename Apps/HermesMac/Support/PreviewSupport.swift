import Foundation
import HermesAppKit
import HermesKit
import SwiftUI

/// Helpers that let every `#Preview` render a real workspace with no socket.
///
/// Each one is an ordinary `AppModel` over `PreviewGatewayClient`, driven through the same
/// event stream the live app uses — so a preview of an approval card is a preview of the
/// card *in place*, not a hand-assembled mock that could drift from the real path.

extension WorkspaceStore {
    /// Attach the preview client: `start()` + open the first session, no pairing sheet.
    func attachPreviewHost() async {
        await model.start()
        await openFirstSessionIfNeeded()
        if model.selectedSessionID == nil, let first = model.sessions.first {
            await model.select(first.id)
        }
    }
}

/// A workspace over one preview scenario.
@MainActor
enum PreviewWorkspace {
    static func model(_ scenario: PreviewGatewayClient.Scenario = .sessions) -> AppModel {
        AppModel(client: PreviewGatewayClient(scenario: scenario), hostName: "hermes")
    }

    static func store(_ scenario: PreviewGatewayClient.Scenario = .sessions) -> WorkspaceStore {
        WorkspaceStore(model: model(scenario))
    }

    /// A pairing that looks real and opens no socket.
    static let address = PairingAddress(baseURL: "wss://hermes.example.ts.net",
                                        deviceID: "preview-device",
                                        token: "preview-refresh")
}
