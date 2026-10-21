import Foundation
import Testing
import UnrealityCore

@MainActor
@Suite("ActivityCoordinator boundaries")
struct CoordinatorBoundaryTests {
    private let vault = FrontmostApp(bundleID: "com.1password.1password", name: "1Password", processID: 300)

    /// Records signals, rendering boundaries as seconds since the fake clock's start.
    @MainActor
    private final class SignalRecorder {
        var signals: [ActivitySignal] = []
        func record(_ signal: ActivitySignal) { signals.append(signal) }
        var boundaries: [TimeInterval] {
            signals.compactMap { signal in
                if case let .boundary(boundary) = signal { return boundary.timestamp.timeIntervalSinceReferenceDate }
                return nil
            }
        }
        var bundleIDs: [String?] {
            signals.compactMap { signal in
                if case let .sample(sample) = signal { return sample.app.bundleID }
                return nil
            }
        }
    }

    @Test("a sample the privacy filter drops becomes an anonymous boundary at its time")
    func excludedAppBoundary() {
        let harness = Harness(filter: PrivacyFilter())
        let recorder = SignalRecorder()
        harness.coordinator.startSignals(recorder.record)
        harness.clock.advance(by: .seconds(10))
        harness.source.activate(vault, title: "Vault: bank login")
        harness.clock.advance(by: .seconds(5))
        harness.source.activate(editor, title: "notes.txt")
        #expect(recorder.bundleIDs == ["com.example.files", "com.example.editor"])
        #expect(recorder.boundaries == [10])
        #expect(recorder.signals.count == 3)
    }

    @Test("pausing delivers a boundary at the clock's time; resuming delivers a fresh snapshot")
    func pauseBoundary() {
        let harness = Harness()
        let recorder = SignalRecorder()
        harness.coordinator.startSignals(recorder.record)
        harness.clock.advance(by: .seconds(30))
        harness.store.pause()
        harness.clock.advance(by: .seconds(60))
        harness.store.resume()
        #expect(recorder.boundaries == [30])
        #expect(recorder.signals.last == .sample(ActivitySample(
            timestamp: Date(timeIntervalSinceReferenceDate: 90), trigger: .snapshot, app: finder,
            windowTitle: "Downloads"
        )))
    }

    @Test("stop delivers a final boundary, but not again after a pause")
    func stopBoundary() {
        let harness = Harness()
        let recorder = SignalRecorder()
        harness.coordinator.startSignals(recorder.record)
        harness.clock.advance(by: .seconds(5))
        harness.coordinator.stop()
        harness.coordinator.stop()
        #expect(recorder.boundaries == [5])

        let paused = Harness()
        let pausedRecorder = SignalRecorder()
        paused.coordinator.startSignals(pausedRecorder.record)
        paused.clock.advance(by: .seconds(5))
        paused.store.pause()
        paused.clock.advance(by: .seconds(5))
        paused.coordinator.stop()
        #expect(pausedRecorder.boundaries == [5])
    }

    @Test("a title change dropped for lack of trust is not a boundary (the app is still in use)")
    func untrustedTitleChangeIsNotABoundary() {
        let source = UnrulySource()
        let coordinator = ActivityCoordinator(
            source: source, captureState: CaptureStateStore(), trust: FakeAccessibilityTrust(state: .notTrusted),
            filter: AllowAllFilter(), clock: FakeTime()
        )
        let recorder = SignalRecorder()
        coordinator.startSignals(recorder.record)
        source.send(.appActivated, title: "secret")
        source.send(.titleChanged, title: "other")
        #expect(recorder.boundaries.isEmpty)
        #expect(recorder.signals.count == 1)
    }

    @Test("start(_:) still delivers samples only")
    func legacyStartHasNoBoundaries() {
        let harness = Harness(filter: PrivacyFilter())
        let recorder = Recorder()
        harness.coordinator.start(recorder.record)
        harness.source.activate(vault, title: "Vault")
        harness.store.pause()
        #expect(recorder.samples.map(\.app.bundleID) == ["com.example.files"])
    }
}
