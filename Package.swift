// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HermesApps",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HermesKit", targets: ["HermesKit"]),
        .library(name: "HermeyUI", targets: ["HermeyUI"]),
        .library(name: "HermesRender", targets: ["HermesRender"]),
        .library(name: "HermesAppKit", targets: ["HermesAppKit"]),
        .library(name: "HermesA2UI", targets: ["HermesA2UI"]),
        .library(name: "HermesCards", targets: ["HermesCards"]),
    ],
    dependencies: [
        // Agent-driven UI: the official A2UI Swift renderer. Pinned to the last Swift release
        // (v0.11.0+swift); the protocol version we validate against is v1.0 on both sides.
        // Its manifest is swift-tools-version 6.1, so the build Mac and CI need a 6.1 toolchain
        // (Xcode 16.3+; the macos-26 runners already have it).
        .package(url: "https://github.com/a2ui-project/a2ui", .upToNextMinor(from: "0.11.0")),
    ],
    targets: [
        // Wire protocol, transport, stores. No UI, no SwiftUI.
        .target(name: "HermesKit", path: "Sources/HermesKit"),
        // The house design system: tokens + components.
        .target(name: "HermeyUI", dependencies: ["HermesKit"], path: "Sources/HermeyUI",
                resources: [.process("Resources")]),
        // Incremental markdown / code / tool-output rendering.
        .target(name: "HermesRender", dependencies: ["HermesKit"], path: "Sources/HermesRender"),
        // Shared application state consumed by both app shells.
        .target(name: "HermesAppKit", dependencies: ["HermesKit"], path: "Sources/HermesAppKit"),
        // Native agent cards (`card.v1`): the third renderer, preferred only when its own marker is
        // present. Foundation + SwiftUI, HermesKit only — the theme is injected, so it never imports
        // the design system and can be tested without an app.
        .target(name: "HermesCards", dependencies: ["HermesKit"], path: "Sources/HermesCards"),
        // Native agent-driven UI: decodes the inline A2UI surface a reply carries and draws it
        // with the official SDK's SwiftUI catalog. Isolated in its own target so the parser is
        // testable without a simulator and the app shells only depend on it where they draw.
        .target(name: "HermesA2UI",
                dependencies: [
                    "HermesKit",
                    .product(name: "A2UISwiftCore", package: "a2ui"),
                    .product(name: "A2UISwiftUI", package: "a2ui"),
                    .product(name: "BasicCatalog", package: "a2ui"),
                    .product(name: "BasicCatalogSwiftUI", package: "a2ui"),
                ],
                path: "Sources/HermesA2UI"),
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
        .testTarget(name: "HermesCardsTests", dependencies: ["HermesCards"], path: "Tests/HermesCardsTests"),
        .testTarget(name: "HermesRenderTests", dependencies: ["HermesRender"], path: "Tests/HermesRenderTests"),
        // The design system's own tests: the bot-avatar artwork, geometry and activity rules.
        .testTarget(name: "HermeyUITests", dependencies: ["HermeyUI"], path: "Tests/HermeyUITests"),
        .testTarget(name: "HermesVoiceTests", dependencies: ["HermesVoiceCore"], path: "Tests/HermesVoiceTests"),
        .testTarget(name: "HermesAttachmentTests", dependencies: ["HermesAttachmentCore"], path: "Tests/HermesAttachmentTests"),
        // The surface parser: pure Foundation, so it runs without a simulator or a GPU.
        .testTarget(name: "HermesA2UITests", dependencies: ["HermesA2UI"], path: "Tests/HermesA2UITests"),
    ]
)
