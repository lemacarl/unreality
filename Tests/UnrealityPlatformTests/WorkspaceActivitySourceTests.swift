import AppKit
import Foundation
import Testing
import UnrealityCore
@testable import UnrealityPlatform

@MainActor
@Suite("WorkspaceActivitySource")
struct WorkspaceActivitySourceTests {
    @Test("the trust check answers without prompting")
    func trustCheck() {
        // Only `currentState()`: `requestAccess()` would show a system prompt.
        let state = SystemAccessibilityTrust().currentState()
        #expect(AccessibilityTrustState.allCases.contains(state))
    }

    @Test("with titles refused, the snapshot is app-only; stop stops")
    func appOnlySnapshot() {
        let source = WorkspaceActivitySource()
        var samples: [ActivitySample] = []
        source.start(windowTitlePolicy: { _ in false }, handler: { samples.append($0) })
        #expect(source.isRunning)
        // CI runners may have no frontmost app, so a snapshot is optional.
        #expect(samples.count <= 1)
        #expect(samples.allSatisfy { $0.trigger == .snapshot && $0.windowTitle == nil })
        source.stop()
        #expect(!source.isRunning)
    }
}

/// Real app switches and title changes, run on demand only (CONTRIBUTING.md,
/// "Manual checks"): it makes Finder frontmost and opens two Finder windows
/// on empty temporary folders. Prints counts only, never titles.
@MainActor
@Suite(
    "WorkspaceActivitySource integration",
    .enabled(if: ProcessInfo.processInfo.environment["UNREALITY_ACTIVITY_TESTS"] == "1")
)
struct WorkspaceActivitySourceIntegrationTests {
    private static let finderID = "com.apple.finder"

    @Test("app switches and Finder title changes are reported", .timeLimit(.minutes(1)))
    func appSwitchAndTitleChange() async throws {
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderID).first)
        let previous = NSWorkspace.shared.frontmostApplication
        try #require(previous?.bundleIdentifier != Self.finderID, "Run it from an app other than Finder")
        let trusted = SystemAccessibilityTrust().currentState() == .trusted
        let folders = try ["A", "B"].map(makeEmptyFolder)
        let source = WorkspaceActivitySource()
        var samples: [ActivitySample] = []
        var policyAsked = false
        source.start(
            windowTitlePolicy: { _ in
                policyAsked = true
                return true
            },
            handler: { samples.append($0) }
        )
        defer {
            source.stop()
            previous?.activate()
            folders.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        let finderSamples = { samples.filter { $0.app.bundleID == Self.finderID } }
        let finderActivated = { finderSamples().contains { $0.trigger == .appActivated } }
        let finderTitleChanges = { finderSamples().filter { $0.trigger == .titleChanged }.count }

        finder.activate()
        try await wait(until: finderActivated)
        // Each folder opens in a new, focused Finder window: focused-window
        // change -> AXObserver callback -> .titleChanged (only when trusted).
        for folder in folders {
            let before = finderTitleChanges()
            NSWorkspace.shared.open(folder)
            try await wait(seconds: 3) { trusted && finderTitleChanges() > before }
        }

        let titledFinder = finderSamples().filter { $0.windowTitle != nil }.count
        let titleChanges = samples.filter { $0.trigger == .titleChanged }.count
        // Counts only, never title text (it can be sensitive).
        print("""
            Accessibility trusted: \(trusted); samples: \(samples.count); \
            Finder samples with a title: \(titledFinder); Finder title changes: \(finderTitleChanges()); \
            all title changes: \(titleChanges)
            """)
        #expect(finderActivated())
        #expect(policyAsked)
        if trusted {
            #expect(titledFinder >= 1)
            #expect(finderTitleChanges() >= 1)
        } else {
            #expect(samples.allSatisfy { $0.windowTitle == nil })
            #expect(titleChanges == 0)
        }
    }

    /// An empty temporary folder with a neutral name (its window title).
    private func makeEmptyFolder(_ suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unreality-ax-test-\(UUID().uuidString)-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Waits until `condition` holds or `seconds` pass (then returns anyway).
    private func wait(seconds: Int = 5, until condition: () -> Bool) async throws {
        for _ in 0..<(seconds * 10) where !condition() {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
