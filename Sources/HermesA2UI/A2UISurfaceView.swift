#if canImport(SwiftUI)
import Combine
import SwiftUI
import A2UICore
import A2UISwiftUI
import BasicCatalog
import BasicCatalogSwiftUI

/// Draws one inline A2UI surface with native SwiftUI widgets.
///
/// The surface arrives as validated wire JSON inside the reply (`A2UISurfacePayload`); this view
/// feeds it to the SDK's own processor and renders the component tree with the Basic catalog.
/// Styling comes from the surrounding `HermeyUI` environment — the protocol carries no theme in
/// v1.0, which is exactly right for us: the app decides how a card looks.
///
/// Actions (a tapped Button) are the one piece not wired yet. The SDK hands them out through
/// `MessageProcessor.outboundListener` (`RendererToAgentMessage`) and
/// `ActionHandling.handle(action:from:)`; both need the transcript's send path, which is the next
/// step once this view compiles against the real package.
@available(macOS 14, iOS 17, *)
public struct A2UISurfaceView: View {
    private let payload: A2UISurfacePayload
    @StateObject private var host: A2UISurfaceHost

    public init(payload: A2UISurfacePayload) {
        self.payload = payload
        _host = StateObject(wrappedValue: A2UISurfaceHost(payload: payload))
    }

    public var body: some View {
        Group {
            if let model = host.surfaceModel {
                Surface(viewModel: model, catalogs: BasicCatalogImplementation.allCatalogs)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Nothing to draw yet (or the payload was refused): the surrounding text carries
                // the answer, so an empty view is the honest failure.
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Owns the A2UI processor for one surface and republishes the model the view renders.
@available(macOS 14, iOS 17, *)
@MainActor
final class A2UISurfaceHost: ObservableObject {
    @Published private(set) var surfaceModel: SurfaceViewModel?
    private let processor: MessageProcessor
    private var cancellables: Set<AnyCancellable> = []

    init(payload: A2UISurfacePayload) {
        // `.relaxed` validation is the SDK's default for streamed surfaces: a surface may arrive
        // in several messages, and strict mode would refuse a partially built tree.
        processor = MessageProcessor(catalogs: BasicCatalog.allCatalogs)
        processor.surfaceGroupModel.$surfacesMap
            .receive(on: RunLoop.main)
            .sink { [weak self] surfaces in
                self?.surfaceModel = surfaces[payload.surface] ?? surfaces.values.first
            }
            .store(in: &cancellables)
        ingest(payload)
    }

    private func ingest(_ payload: A2UISurfacePayload) {
        for json in payload.messagesJSON {
            guard let message = try? MessageParser().parse(jsonString: json) else { continue }
            processor.process(message: message)
        }
    }
}
#endif
