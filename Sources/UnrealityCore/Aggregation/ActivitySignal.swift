import Foundation

/// An anonymous point in time at which tracked activity stopped: the
/// privacy filter dropped a sample (an excluded app became frontmost),
/// capture was paused, or the coordinator was stopped.
///
/// It carries only a timestamp, deliberately no reason, app, title or URL,
/// so it reveals nothing about what was in use. Span aggregation treats it
/// as the end of the previous span, so time in an excluded app is never
/// attributed to the app used before it (#21).
public struct ActivityBoundary: Sendable, Hashable {
    public let timestamp: Date

    public init(timestamp: Date) {
        self.timestamp = timestamp
    }
}

/// What `ActivityCoordinator.start(signals:)` delivers: a filtered sample,
/// or an anonymous boundary where tracked activity stopped.
public enum ActivitySignal: Sendable, Equatable {
    /// A sample that passed the coordinator's rules and the privacy filter.
    case sample(ActivitySample)
    /// Tracked activity stopped here (see ``ActivityBoundary``).
    case boundary(ActivityBoundary)
}
