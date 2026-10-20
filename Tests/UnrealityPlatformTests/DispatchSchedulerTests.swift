import Foundation
import Testing
import UnrealityCore
@testable import UnrealityPlatform

@Suite("DispatchScheduler")
struct DispatchSchedulerTests {
    @Test("runs scheduled work after the delay", .timeLimit(.minutes(1)))
    func runsWork() async {
        await withCheckedContinuation { continuation in
            DispatchScheduler().schedule(after: .milliseconds(10), repeating: nil) {
                continuation.resume()
            }
        }
    }

    @Test("cancelled work does not run")
    func cancel() async throws {
        let fired = Flag()
        let work = DispatchScheduler().schedule(after: .milliseconds(50), repeating: nil) { fired.set() }
        work.cancel()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!fired.value)
    }

    @Test("intervals convert to nanoseconds without overflow")
    func intervalConversion() {
        #expect(DispatchScheduler.dispatchInterval(.milliseconds(1_500)) == .nanoseconds(1_500_000_000))
        #expect(DispatchScheduler.dispatchInterval(.seconds(Int64.max)) == .nanoseconds(.max))
    }

    @Test("SystemClock tracks the system time")
    func systemClock() {
        #expect(abs(SystemClock().now().timeIntervalSinceNow) < 1)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}
