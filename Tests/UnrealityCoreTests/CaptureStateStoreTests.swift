import Observation
import Testing
import UnrealityCore

@MainActor
@Suite("CaptureStateStore")
struct CaptureStateStoreTests {
    @Test("starts running by default")
    func defaultsToRunning() {
        let store = CaptureStateStore()
        #expect(store.state == .running)
        #expect(!store.isPaused)
    }

    @Test("honours an explicit initial state", arguments: CaptureState.allCases)
    func initialState(_ initial: CaptureState) {
        #expect(CaptureStateStore(initialState: initial).state == initial)
    }

    @Test("pause moves running to paused")
    func pause() {
        let store = CaptureStateStore()
        store.pause()
        #expect(store.state == .paused)
        #expect(store.isPaused)
    }

    @Test("resume moves paused to running")
    func resume() {
        let store = CaptureStateStore(initialState: .paused)
        store.resume()
        #expect(store.state == .running)
        #expect(!store.isPaused)
    }

    @Test("pause and resume are idempotent")
    func idempotent() {
        let store = CaptureStateStore()
        store.resume()
        #expect(store.state == .running)
        store.pause()
        store.pause()
        #expect(store.state == .paused)
    }

    @Test("toggle alternates between running and paused")
    func toggle() {
        let store = CaptureStateStore()
        store.toggle()
        #expect(store.state == .paused)
        store.toggle()
        #expect(store.state == .running)
    }

    @Test("toggled maps each state to the other")
    func toggledMapping() {
        #expect(CaptureState.running.toggled == .paused)
        #expect(CaptureState.paused.toggled == .running)
    }

    @Test("a state change notifies observers")
    func notifiesOnChange() {
        let store = CaptureStateStore()
        let flag = ChangeFlag()
        withObservationTracking {
            _ = store.state
        } onChange: {
            flag.set()
        }
        store.pause()
        #expect(flag.value)
    }

    @Test("a same-state write does not notify observers")
    func noNotificationWithoutChange() {
        let store = CaptureStateStore()
        let flag = ChangeFlag()
        withObservationTracking {
            _ = store.state
        } onChange: {
            flag.set()
        }
        store.resume()
        #expect(!flag.value)
    }
}

/// Sendable box for the `@Sendable` onChange closure.
private final class ChangeFlag: @unchecked Sendable {
    // Only touched synchronously on the main actor within one test.
    private(set) var value = false
    func set() { value = true }
}
