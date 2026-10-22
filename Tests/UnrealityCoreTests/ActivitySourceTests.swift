import Foundation
import Testing
import UnrealityCore

let finder = FrontmostApp(bundleID: "com.example.files", name: "Files", processID: 10)
let editor = FrontmostApp(bundleID: "com.example.editor", name: "Editor", processID: 20)

/// Collects samples delivered to a handler or sink.
@MainActor
final class Recorder {
    var samples: [ActivitySample] = []
    var triggers: [ActivitySample.Trigger] { samples.map(\.trigger) }
    var titles: [String?] { samples.map(\.windowTitle) }
    func record(_ sample: ActivitySample) { samples.append(sample) }
}

@MainActor
@Suite("FakeActivitySource")
struct FakeActivitySourceTests {
    @Test("emits a snapshot on start, then app activations and title changes")
    func emitsOnAppAndTitleChange() {
        let time = FakeTime()
        let source = FakeActivitySource(clock: time, frontmost: finder, title: "Downloads")
        let recorder = Recorder()
        source.start(windowTitlePolicy: { _ in true }, handler: recorder.record)
        time.advance(by: .seconds(5))
        source.activate(editor, title: "notes.txt")
        source.setTitle("todo.txt")

        #expect(recorder.triggers == [.snapshot, .appActivated, .titleChanged])
        #expect(recorder.samples.map(\.app) == [finder, editor, editor])
        #expect(recorder.titles == ["Downloads", "notes.txt", "todo.txt"])
        #expect(recorder.samples[1].timestamp == Date(timeIntervalSinceReferenceDate: 5))
    }

    @Test("an unchanged title emits nothing")
    func unchangedTitle() {
        let source = FakeActivitySource(frontmost: editor, title: "a")
        let recorder = Recorder()
        source.start(windowTitlePolicy: { _ in true }, handler: recorder.record)
        source.setTitle("a")
        #expect(recorder.triggers == [.snapshot])
    }

    @Test("a policy that says no gives app-only samples and no title changes")
    func policyRefusesTitles() {
        let source = FakeActivitySource(frontmost: finder, title: "secret")
        let recorder = Recorder()
        source.start(windowTitlePolicy: { $0 != editor }, handler: recorder.record)
        source.activate(editor, title: "private")
        source.setTitle("more private")
        #expect(recorder.triggers == [.snapshot, .appActivated])
        #expect(recorder.titles == ["secret", nil])
    }

    @Test("nothing is emitted after stop")
    func stop() {
        let source = FakeActivitySource(frontmost: finder)
        let recorder = Recorder()
        source.start(windowTitlePolicy: { _ in true }, handler: recorder.record)
        source.stop()
        source.activate(editor)
        source.setTitle("x")
        #expect(!source.isRunning)
        #expect(recorder.triggers == [.snapshot])
    }

    @Test("no snapshot when nothing is frontmost")
    func noFrontmost() {
        let source = FakeActivitySource()
        let recorder = Recorder()
        source.start(windowTitlePolicy: { _ in true }, handler: recorder.record)
        #expect(recorder.samples.isEmpty)
    }
}

/// Filter double that lets everything through (tests only: production code
/// has no pass-through filter).
@MainActor
final class AllowAllFilter: ActivitySampleFilter {
    func allowsWindowTitle(for app: FrontmostApp) -> Bool { true }
    func filter(_ sample: ActivitySample) -> ActivitySample? { sample }
}

/// Filter double: excludes some apps' titles and drops some samples.
@MainActor
final class StubFilter: ActivitySampleFilter {
    var titleExcluded: Set<String> = []
    var dropped: Set<String> = []
    func allowsWindowTitle(for app: FrontmostApp) -> Bool { !titleExcluded.contains(app.bundleID ?? "") }
    func filter(_ sample: ActivitySample) -> ActivitySample? {
        dropped.contains(sample.app.bundleID ?? "") ? nil : sample
    }
}

/// Source double that ignores the policy, to prove the coordinator does not
/// rely on sources behaving.
@MainActor
final class UnrulySource: ActivitySource {
    var isRunning = false
    var handler: (@MainActor (ActivitySample) -> Void)?
    func start(windowTitlePolicy: @escaping WindowTitlePolicy, handler: @escaping @MainActor (ActivitySample) -> Void) {
        isRunning = true
        self.handler = handler
    }
    func stop() { isRunning = false }
    func send(_ trigger: ActivitySample.Trigger, app: FrontmostApp = finder, title: String?) {
        handler?(ActivitySample(timestamp: Date(), trigger: trigger, app: app, windowTitle: title))
    }
}

/// A coordinator wired to fakes (shared with ActivityCoordinatorTests.swift).
@MainActor
struct Harness {
    let clock = FakeTime()
    let source: FakeActivitySource
    let store: CaptureStateStore
    let trust: FakeAccessibilityTrust
    let coordinator: ActivityCoordinator

    init(
        trust: AccessibilityTrustState = .trusted,
        paused: Bool = false,
        filter: any ActivitySampleFilter = AllowAllFilter()
    ) {
        source = FakeActivitySource(clock: clock, frontmost: finder, title: "Downloads")
        store = CaptureStateStore(initialState: paused ? .paused : .running)
        self.trust = FakeAccessibilityTrust(state: trust)
        coordinator = ActivityCoordinator(
            source: source, captureState: store, trust: self.trust, filter: filter, clock: clock
        )
    }
}

@MainActor
@Suite("CaptureStateStore change handlers")
struct CaptureStateChangeTests {
    @Test("handlers run after each change until cancelled")
    func onChange() {
        let store = CaptureStateStore()
        var seen: [CaptureState] = []
        let subscription = store.onChange { seen.append($0) }
        store.pause()
        store.pause()
        store.resume()
        subscription.cancel()
        subscription.cancel()
        store.pause()
        #expect(seen == [.paused, .running])
    }
}
