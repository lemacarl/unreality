import Dispatch
import Foundation
import UnrealityCore

/// `WallClock` reading the system clock.
public struct SystemClock: WallClock {
    public init() {}

    public func now() -> Date { Date() }
}

/// `Scheduler` backed by `DispatchSourceTimer`; actions run on `queue`.
/// One-shot work is released after it runs; repeating work until cancelled.
public struct DispatchScheduler: Scheduler {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .global(qos: .utility)) {
        self.queue = queue
    }

    @discardableResult
    public func schedule(
        after delay: Duration,
        repeating interval: Duration?,
        _ action: @escaping @Sendable () -> Void
    ) -> ScheduledWork {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let repeatInterval = interval.flatMap { $0 > .zero ? Self.dispatchInterval($0) : nil }
        timer.schedule(deadline: .now() + Self.dispatchInterval(max(delay, .zero)), repeating: repeatInterval ?? .never)
        // The handler captures the timer, keeping it alive until it is
        // cancelled (Dispatch releases the handler then), so callers may
        // discard the returned handle.
        timer.setEventHandler {
            action()
            if repeatInterval == nil { timer.cancel() }
        }
        timer.resume()
        return ScheduledWork { timer.cancel() }
    }

    /// Whole nanoseconds of a non-negative `duration`, saturating at
    /// `Int.max` (about 292 years) instead of overflowing.
    static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (total, overflow2) = Int(whole).addingReportingOverflow(Int(attoseconds / 1_000_000_000))
        return .nanoseconds(overflow || overflow2 ? .max : total)
    }
}
