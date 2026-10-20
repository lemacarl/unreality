import Foundation

/// Source of wall-clock time. Inject it instead of calling `Date()` so
/// time-dependent logic is testable. Named `WallClock` rather than `Clock`
/// to avoid clashing with the standard library's `Clock` protocol.
public protocol WallClock: Sendable {
    func now() -> Date
}

/// Handle for work given to a `Scheduler`. Cancelling twice is harmless.
public final class ScheduledWork: Sendable {
    private let onCancel: @Sendable () -> Void

    public init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    /// Stops the work from running again. Work already running is not interrupted.
    public func cancel() {
        onCancel()
    }
}

/// Runs work after a delay, optionally repeating. Inject it instead of using
/// timers directly. Implementations say which thread `action` runs on.
public protocol Scheduler: Sendable {
    /// Runs `action` once after `delay`, then every `interval` (if given and
    /// positive) until cancelled.
    @discardableResult
    func schedule(
        after delay: Duration,
        repeating interval: Duration?,
        _ action: @escaping @Sendable () -> Void
    ) -> ScheduledWork
}

/// Test double for `WallClock` and `Scheduler`: time stands still until
/// `advance(by:)`, which moves `now()` forward and runs due work in time
/// order, synchronously on the caller's thread. Work due at the same time
/// runs in the order it was scheduled (a repeat counts as rescheduled each
/// time it runs). Actions may schedule, cancel or call `advance` again;
/// time never moves backwards.
public final class FakeTime: WallClock, Scheduler, @unchecked Sendable {
    private struct Item {
        let id: Int
        var due: Duration
        let interval: Duration?
        let action: @Sendable () -> Void
    }

    // All mutable state is guarded by `lock`; actions run outside it.
    private let lock = NSLock()
    private let start: Date
    private var elapsed: Duration = .zero
    private var items: [Item] = []
    private var lastID = 0

    public init(start: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.start = start
    }

    public func now() -> Date {
        lock.withLock { start.addingTimeInterval(elapsed.timeInterval) }
    }

    /// Number of scheduled, uncancelled items.
    public var pendingCount: Int {
        lock.withLock { items.count }
    }

    @discardableResult
    public func schedule(
        after delay: Duration,
        repeating interval: Duration?,
        _ action: @escaping @Sendable () -> Void
    ) -> ScheduledWork {
        let id = lock.withLock {
            lastID += 1
            let repeatInterval = interval.flatMap { $0 > .zero ? $0 : nil }
            items.append(Item(id: lastID, due: elapsed + max(delay, .zero), interval: repeatInterval, action: action))
            return lastID
        }
        return ScheduledWork { [weak self] in
            guard let self else { return }
            lock.withLock { items.removeAll { $0.id == id } }
        }
    }

    /// Moves time forward by `duration` (which must not be negative),
    /// running every item that falls due.
    public func advance(by duration: Duration) {
        precondition(duration >= .zero, "FakeTime cannot move backwards")
        let target = lock.withLock { elapsed + duration }
        while let action = takeNextDue(notAfter: target) {
            action()
        }
        // A nested advance may already have moved past `target`.
        lock.withLock { elapsed = max(elapsed, target) }
    }

    private func takeNextDue(notAfter target: Duration) -> (@Sendable () -> Void)? {
        lock.withLock {
            let due = items.indices.filter { items[$0].due <= target }
            guard let index = due.min(by: { items[$0].due < items[$1].due }) else { return nil }
            var item = items.remove(at: index)
            elapsed = max(elapsed, item.due)
            if let interval = item.interval {
                item.due += interval
                items.append(item)
            }
            return item.action
        }
    }
}

extension Duration {
    /// The duration in seconds, for `Date` APIs.
    public var timeInterval: TimeInterval {
        let (whole, attoseconds) = components
        return TimeInterval(whole) + TimeInterval(attoseconds) * 1e-18
    }
}
