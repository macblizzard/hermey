// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HermesApps",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HermesKit", targets: ["HermesKit"]),
        .library(name: "OpenBotUI", targets: ["OpenBotUI"]),
        .library(name: "HermesRender", targets: ["HermesRender"]),
        .library(name: "HermesAppKit", targets: ["HermesAppKit"]),
    ],
    targets: [
        // Wire protocol, transport, stores. No UI, no SwiftUI.
        .target(name: "HermesKit", path: "Sources/HermesKit"),
        // The OpenBot design system: tokens + components.
        .target(name: "OpenBotUI", dependencies: ["HermesKit"], path: "Sources/OpenBotUI"),
        // Incremental markdown / code / tool-output rendering.
        .target(name: "HermesRender", dependencies: ["HermesKit"], path: "Sources/HermesRender"),
        // Shared application state consumed by both app shells.
        .target(name: "HermesAppKit", dependencies: ["HermesKit"], path: "Sources/HermesAppKit"),
        // The phone's bridge voice client, compiled here (Foundation only, no SwiftUI)
        // so it can be unit-tested without an iOS simulator. The iOS target compiles
        // the same two files as part of the app module.
        .target(name: "HermesVoiceCore",
                path: "Apps/HermesMobile/Networking",
                sources: ["VoiceTransport.swift", "VoiceService.swift"]),
        // The attachment budget, name rules and downscaling ladder: Foundation only, for the
        // same reason as the voice core — the decisions can be tested without a simulator.
        .target(name: "HermesAttachmentCore",
                path: "Apps/HermesMobile/Networking",
                sources: ["AttachmentBudget.swift"]),

        .testTarget(name: "HermesKitTests", dependencies: ["HermesKit"], path: "Tests/HermesKitTests"),
        .testTarget(name: "HermesAppKitTests", dependencies: ["HermesAppKit"], path: "Tests/HermesAppKitTests"),
        .testTarget(name: "HermesRenderTests", dependencies: ["HermesRender"], path: "Tests/HermesRenderTests"),
        .testTarget(name: "HermesVoiceTests", dependencies: ["HermesVoiceCore"], path: "Tests/HermesVoiceTests"),
        .testTarget(name: "HermesAttachmentTests", dependencies: ["HermesAttachmentCore"], path: "Tests/HermesAttachmentTests"),
    ]
)
