// swift-tools-version: 6.0
// Swift 6 language mode (complete strict concurrency) for every target.
// See docs/ARCHITECTURE.md, "Swift language mode".

import PackageDescription

let package = Package(
    name: "Unreality",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UnrealityCore", targets: ["UnrealityCore"]),
        .library(name: "UnrealityPlatform", targets: ["UnrealityPlatform"])
    ],
    targets: [
        // Pure logic and domain types. Must not import AppKit, SwiftUI,
        // ScreenCaptureKit, AVFoundation, Vision or other OS frameworks
        // (enforced by the `core_no_os_imports` SwiftLint rule).
        .target(name: "UnrealityCore"),
        // Real implementations of the protocols declared in UnrealityCore.
        .target(
            name: "UnrealityPlatform",
            dependencies: ["UnrealityCore"]
        ),
        .testTarget(
            name: "UnrealityCoreTests",
            dependencies: ["UnrealityCore"]
        ),
        .testTarget(
            name: "UnrealityPlatformTests",
            dependencies: ["UnrealityPlatform"]
        )
    ],
    swiftLanguageModes: [.v6]
)
