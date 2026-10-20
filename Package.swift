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
    dependencies: [
        // ADR 0002. Exact pin; bump deliberately (CONTRIBUTING.md, "Tool versions").
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        // Pure logic, domain types and storage. May import only Foundation,
        // Dispatch, Observation, Synchronization, RegexBuilder and GRDB
        // (ADR 0002): a regex-based guard
        // (SwiftLint `core_no_os_imports`, `core_tests_no_os_imports` for its
        // tests), backed in CI by scripts/ci/check-core-imports.py.
        .target(
            name: "UnrealityCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
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
