import Foundation
import Testing
import UnrealityCore

@Suite("FakeTime")
struct FakeTimeTests {
    @Test("now() stands still until advanced")
    func clockAdvances() {
        let start = Date(timeIntervalSince1970: 1_000)
        let time = FakeTime(start: start)
        #expect(time.now() == start)
        time.advance(by: .milliseconds(1_500))
        #expect(time.now() == start.addingTimeInterval(1.5))
    }

    @Test("one-shot work runs once when due, at its due time")
    func oneShot() {
        let time = FakeTime()
        let log = Log()
        time.schedule(after: .seconds(2), repeating: nil) { log.append(time.now()) }
        time.advance(by: .seconds(1))
        #expect(log.values.isEmpty)
        time.advance(by: .seconds(5))
        #expect(log.values == [Date(timeIntervalSinceReferenceDate: 2)])
        #expect(time.pendingCount == 0)
    }

    @Test("repeating work runs every interval")
    func repeating() {
        let time = FakeTime()
        let log = Log()
        time.schedule(after: .seconds(1), repeating: .seconds(2)) { log.append(time.now()) }
        time.advance(by: .seconds(6))
        #expect(log.values.map(\.timeIntervalSinceReferenceDate) == [1, 3, 5])
    }

    @Test("due work runs in time order")
    func ordering() {
        let time = FakeTime()
        let log = Log()
        time.schedule(after: .seconds(3), repeating: nil) { log.append(Date(timeIntervalSinceReferenceDate: 3)) }
        time.schedule(after: .seconds(1), repeating: nil) { log.append(Date(timeIntervalSinceReferenceDate: 1)) }
        time.advance(by: .seconds(5))
        #expect(log.values.map(\.timeIntervalSinceReferenceDate) == [1, 3])
    }

    @Test("work due at the same time runs in scheduling order")
    func equalDueTimes() {
        let time = FakeTime()
        let log = Log()
        for second in [1.0, 2.0, 3.0] {
            let marker = Date(timeIntervalSinceReferenceDate: second)
            time.schedule(after: .seconds(1), repeating: nil) { log.append(marker) }
        }
        time.advance(by: .seconds(1))
        #expect(log.values.map(\.timeIntervalSinceReferenceDate) == [1, 2, 3])
    }

    @Test("zero-delay work scheduled from an action runs in the same advance")
    func zeroDelayFromAction() {
        let time = FakeTime()
        let log = Log()
        time.schedule(after: .seconds(1), repeating: nil) {
            time.schedule(after: .zero, repeating: nil) { log.append(time.now()) }
        }
        time.advance(by: .seconds(1))
        #expect(log.values == [Date(timeIntervalSinceReferenceDate: 1)])
    }

    @Test("a repeating action can cancel itself")
    func cancelFromRepeatingAction() {
        let time = FakeTime()
        let log = Log()
        let holder = WorkHolder()
        holder.work = time.schedule(after: .seconds(1), repeating: .seconds(1)) {
            log.append(time.now())
            if log.values.count == 2 { holder.work?.cancel() }
        }
        time.advance(by: .seconds(10))
        #expect(log.values.count == 2)
        #expect(time.pendingCount == 0)
    }

    @Test("a nested advance is not undone by the outer one")
    func nestedAdvance() {
        let time = FakeTime()
        time.schedule(after: .seconds(1), repeating: nil) { time.advance(by: .seconds(5)) }
        time.advance(by: .seconds(2))
        #expect(time.now() == Date(timeIntervalSinceReferenceDate: 6))
    }

    @Test("cancelled work does not run")
    func cancel() {
        let time = FakeTime()
        let log = Log()
        let work = time.schedule(after: .seconds(1), repeating: .seconds(1)) { log.append(time.now()) }
        time.advance(by: .seconds(2))
        work.cancel()
        work.cancel()
        time.advance(by: .seconds(5))
        #expect(log.values.count == 2)
        #expect(time.pendingCount == 0)
    }
}

/// Lets an action reach its own `ScheduledWork`.
private final class WorkHolder: @unchecked Sendable {
    // Set before `advance`; read only from actions on the same thread.
    var work: ScheduledWork?
}

/// Thread-safe append-only log for `@Sendable` actions.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Date] = []
    var values: [Date] { lock.withLock { storage } }
    func append(_ date: Date) { lock.withLock { storage.append(date) } }
}
