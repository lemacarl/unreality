import Foundation
import Testing
import UnrealityCore

@MainActor
@Suite("ActivityCoordinator")
struct ActivityCoordinatorTests {
    @Test("forwards app and title samples while running and trusted")
    func forwards() {
        let harness = Harness()
        let source = harness.source
        let coordinator = harness.coordinator
        let recorder = Recorder()
        coordinator.start(recorder.record)
        source.activate(editor, title: "notes.txt")
        source.setTitle("todo.txt")
        #expect(coordinator.isActive)
        #expect(recorder.triggers == [.snapshot, .appActivated, .titleChanged])
        #expect(recorder.titles == ["Downloads", "notes.txt", "todo.txt"])
    }

    @Test("without Accessibility trust samples are app-only and the state says so")
    func degradesWithoutTrust() {
        let harness = Harness(trust: .notTrusted)
        let source = harness.source
        let trust = harness.trust
        let coordinator = harness.coordinator
        let recorder = Recorder()
        coordinator.start(recorder.record)
        source.activate(editor, title: "notes.txt")
        source.setTitle("todo.txt")
        #expect(coordinator.accessibilityTrust == .notTrusted)
        #expect(recorder.triggers == [.snapshot, .appActivated])
        #expect(recorder.titles == [nil, nil])
        #expect(trust.requestCount == 0, "the coordinator must never prompt")
    }

    @Test("trust granted or revoked later is picked up on the next sample")
    func trustChanges() {
        let harness = Harness(trust: .notTrusted)
        let source = harness.source
        let trust = harness.trust
        let coordinator = harness.coordinator
        let recorder = Recorder()
        coordinator.start(recorder.record)
        trust.state = .trusted
        source.activate(editor, title: "notes.txt")
        #expect(coordinator.accessibilityTrust == .trusted)
        trust.state = .notTrusted
        source.activate(finder, title: "Downloads")
        #expect(coordinator.accessibilityTrust == .notTrusted)
        #expect(recorder.titles == [nil, "notes.txt", nil])
    }

    @Test("refreshAccessibilityTrust updates the published state without prompting")
    func refresh() {
        let harness = Harness(trust: .notTrusted)
        let trust = harness.trust
        let coordinator = harness.coordinator
        trust.state = .trusted
        coordinator.refreshAccessibilityTrust()
        #expect(coordinator.accessibilityTrust == .trusted)
        #expect(trust.requestCount == 0)
    }

    @Test("titles from a source that ignores the policy are still stripped")
    func stripsUnrulySource() {
        let source = UnrulySource()
        let coordinator = ActivityCoordinator(
            source: source,
            captureState: CaptureStateStore(),
            trust: FakeAccessibilityTrust(state: .notTrusted),
            filter: AllowAllFilter()
        )
        let recorder = Recorder()
        coordinator.start(recorder.record)
        source.send(.appActivated, title: "secret")
        source.send(.titleChanged, title: "secret 2")
        #expect(recorder.triggers == [.appActivated])
        #expect(recorder.titles == [nil])
    }

    @Test("paused at start: the source is not started and nothing is emitted")
    func pausedAtStart() {
        let harness = Harness(paused: true)
        let source = harness.source
        let coordinator = harness.coordinator
        let recorder = Recorder()
        coordinator.start(recorder.record)
        source.activate(editor, title: "notes.txt")
        #expect(!source.isRunning)
        #expect(source.startCount == 0)
        #expect(recorder.samples.isEmpty)
    }

    @Test("pausing stops the source; resuming restarts it with a fresh snapshot")
    func pauseAndResume() {
        let harness = Harness()
        let source = harness.source
        let store = harness.store
        let coordinator = harness.coordinator
        let recorder = Recorder()
        coordinator.start(recorder.record)
        store.pause()
        #expect(!source.isRunning)
        source.activate(editor, title: "while paused")
        source.setTitle("still paused")
        #expect(recorder.triggers == [.snapshot])
        store.resume()
        #expect(source.isRunning)
        #expect(recorder.triggers == [.snapshot, .snapshot])
        #expect(recorder.samples.last?.app == editor)
        #expect(recorder.samples.last?.windowTitle == "still paused")
    }

    @Test("a sample that arrives while paused is dropped")
    func dropsWhilePaused() {
        let source = UnrulySource()
        let store = CaptureStateStore()
        let coordinator = ActivityCoordinator(
            source: source,
            captureState: store,
            trust: FakeAccessibilityTrust(state: .trusted),
            filter: AllowAllFilter()
        )
        let recorder = Recorder()
        coordinator.start(recorder.record)
        store.pause()
        source.send(.appActivated, title: "late")
        #expect(recorder.samples.isEmpty)
    }

    @Test("the filter decides which titles are read and which samples pass")
    func filterSeam() {
        let filter = StubFilter()
        filter.titleExcluded = ["com.example.editor"]
        filter.dropped = ["com.example.dropped"]
        let harness = Harness(filter: filter)
        let source = harness.source
        let coordinator = harness.coordinator
        let recorder = Recorder()
        coordinator.start(recorder.record)
        source.activate(editor, title: "private")
        source.setTitle("more private")
        source.activate(FrontmostApp(bundleID: "com.example.dropped", name: "D", processID: 30), title: "x")
        #expect(recorder.samples.map(\.app) == [finder, editor])
        #expect(recorder.titles == ["Downloads", nil])
        // The policy was consulted before each title read (snapshot, editor
        // activation, editor title change, dropped app), not stripped later.
        #expect(source.titlePolicyQueries.map(\.bundleID) == [
            "com.example.files", "com.example.editor", "com.example.editor", "com.example.dropped"
        ])
    }
}

@MainActor
@Suite("ActivityCoordinator lifecycle")
struct ActivityCoordinatorLifecycleTests {
    @Test("start, stop, start again re-subscribes to pause state")
    func restart() {
        let harness = Harness()
        let recorder = Recorder()
        harness.coordinator.start(recorder.record)
        harness.coordinator.stop()
        harness.coordinator.start(recorder.record)
        #expect(harness.source.isRunning)
        harness.store.pause()
        #expect(!harness.source.isRunning)
        harness.store.resume()
        #expect(harness.source.isRunning)
        #expect(recorder.triggers == [.snapshot, .snapshot, .snapshot])
    }

    @Test("a second start replaces the sink")
    func secondStartReplacesSink() {
        let harness = Harness()
        let first = Recorder()
        let second = Recorder()
        harness.coordinator.start(first.record)
        harness.coordinator.start(second.record)
        harness.source.activate(editor, title: "notes.txt")
        #expect(first.triggers == [.snapshot])
        #expect(second.triggers == [.snapshot, .appActivated])
    }

    @Test("a late sample after stop is dropped")
    func dropsAfterStop() {
        let source = UnrulySource()
        let coordinator = ActivityCoordinator(
            source: source,
            captureState: CaptureStateStore(),
            trust: FakeAccessibilityTrust(state: .trusted),
            filter: AllowAllFilter()
        )
        let recorder = Recorder()
        coordinator.start(recorder.record)
        let handler = source.handler
        coordinator.stop()
        handler?(ActivitySample(timestamp: Date(), trigger: .appActivated, app: finder, windowTitle: "late"))
        #expect(recorder.samples.isEmpty)
    }

    @Test("trust revoked while the same app stays frontmost stops title changes")
    func trustRevokedSameApp() {
        let harness = Harness()
        let recorder = Recorder()
        harness.coordinator.start(recorder.record)
        harness.source.setTitle("Documents")
        harness.trust.state = .notTrusted
        harness.source.setTitle("Desktop")
        #expect(recorder.triggers == [.snapshot, .titleChanged])
        #expect(recorder.titles == ["Downloads", "Documents"])
        #expect(harness.coordinator.accessibilityTrust == .notTrusted)
    }

    @Test("trust granted while running restarts the source on refresh")
    func refreshRestartsWhenGranted() {
        let harness = Harness(trust: .notTrusted)
        let recorder = Recorder()
        harness.coordinator.start(recorder.record)
        harness.trust.state = .trusted
        harness.coordinator.refreshAccessibilityTrust()
        #expect(harness.source.startCount == 2)
        #expect(recorder.titles == [nil, "Downloads"])
        harness.coordinator.refreshAccessibilityTrust()
        #expect(harness.source.startCount == 2, "no restart without a change")
    }

    @Test("trust granted while paused does not start the source")
    func refreshWhilePaused() {
        let harness = Harness(trust: .notTrusted, paused: true)
        harness.coordinator.start { _ in }
        harness.trust.state = .trusted
        harness.coordinator.refreshAccessibilityTrust()
        #expect(harness.source.startCount == 0)
    }

    @Test("titles are never read for a process without a bundle ID")
    func noBundleID() {
        let harness = Harness()
        let recorder = Recorder()
        harness.coordinator.start(recorder.record)
        harness.source.activate(FrontmostApp(bundleID: nil, name: "tool", processID: 40), title: "x")
        harness.source.setTitle("y")
        #expect(recorder.triggers == [.snapshot, .appActivated])
        #expect(recorder.titles == ["Downloads", nil])
    }

    @Test("Unreality's own windows are app-only, even from a source that sends titles")
    func ownProcess() {
        let own = FrontmostApp(
            bundleID: "com.example.self", name: "Self", processID: ProcessInfo.processInfo.processIdentifier
        )
        let source = UnrulySource()
        let coordinator = ActivityCoordinator(
            source: source,
            captureState: CaptureStateStore(),
            trust: FakeAccessibilityTrust(state: .trusted),
            filter: AllowAllFilter()
        )
        let recorder = Recorder()
        coordinator.start(recorder.record)
        source.send(.appActivated, app: own, title: "Timeline")
        source.send(.titleChanged, app: own, title: "Settings")
        #expect(recorder.triggers == [.appActivated])
        #expect(recorder.titles == [nil])

        let fake = Harness()
        fake.coordinator.start { _ in }
        fake.source.activate(own, title: "Timeline")
        #expect(!fake.source.titlePolicyQueries.contains(own), "the fake source never asks about itself")
    }

    @Test("stop stops the source and ignores later state changes")
    func stop() {
        let harness = Harness()
        let source = harness.source
        let store = harness.store
        let coordinator = harness.coordinator
        let recorder = Recorder()
        coordinator.start(recorder.record)
        coordinator.stop()
        #expect(!coordinator.isActive)
        #expect(!source.isRunning)
        store.pause()
        store.resume()
        #expect(!source.isRunning)
        #expect(recorder.triggers == [.snapshot])
    }
}
