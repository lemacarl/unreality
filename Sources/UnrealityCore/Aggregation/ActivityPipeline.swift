import Dispatch
import Foundation

/// One write for storage, produced by ``ActivityPipeline``. Events are
/// `FilteredEvent`s only, so nothing unfiltered can be written.
public enum ActivityRecordCommand: Sendable, Equatable {
    /// Open a session at the date. Activity events inserted until the next
    /// `endSession` belong to it.
    case startSession(Date)
    case insert(FilteredEvent)
    /// Close the open session (if any) at the date.
    case endSession(Date)
}

/// Applies ``ActivityRecordCommand``s, in order. Implementations say where
/// the work runs; it must not block the caller (the main actor).
public protocol ActivityRecordWriter: Sendable {
    func write(_ commands: [ActivityRecordCommand])
}

/// Connects capture to storage: feeds ``ActivitySignal``s (from
/// `ActivityCoordinator.startSignals(_:)`) and idle transitions into a
/// ``SpanAggregator`` and writes the completed spans and sessions.
///
/// Events are built when a span is complete, through the app's single
/// `PrivacyFilter` instance and its rules at that moment, never a copy: an
/// app excluded while its span was open is not stored. Idle spans carry no
/// app, title or URL. Anonymous boundaries are never stored; the time
/// between a boundary and the next sample is simply not recorded. A session
/// is written from its first stored event to its last, and a span dropped
/// by the rules ends it like a boundary, so a session never covers dropped
/// time and no empty session is stored.
///
/// A span still open is held in memory until it completes, so it is lost if
/// the app quits without `finish(at:)`.
@MainActor
public final class ActivityPipeline {
    private let filter: PrivacyFilter
    private let writer: any ActivityRecordWriter
    private let source: String
    private var aggregator: SpanAggregator
    /// Whether the aggregator has a session open.
    private var sessionOpen = false
    /// End of the last event stored in the open session; `nil` until one is.
    /// The written session spans its stored events only (the rules may
    /// drop some or all of them).
    private var lastStoredEnd: Date?

    /// - Parameters:
    ///   - filter: the app's single `PrivacyFilter` (also given to the coordinator).
    ///   - source: stored as each event's capture source.
    ///   - calendar: decides where local midnight falls for day splits.
    public init(
        filter: PrivacyFilter,
        writer: any ActivityRecordWriter,
        source: String = "workspace",
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.filter = filter
        self.writer = writer
        self.source = source
        aggregator = SpanAggregator(calendar: calendar)
    }

    /// Whether a span or session is still open (not yet written).
    public var hasPendingActivity: Bool { aggregator.isOpen }

    public func receive(_ signal: ActivitySignal) {
        switch signal {
        case let .sample(sample): consume(.sample(sample))
        case let .boundary(boundary): consume(.boundary(boundary))
        }
    }

    /// The user became idle at `date` (idle detection, #18).
    public func idleStarted(at date: Date) { consume(.idleStarted(date)) }

    /// The user is back at `date`.
    public func idleEnded(at date: Date) { consume(.idleEnded(date)) }

    /// Ends and writes whatever is open at `date`, for example at quit.
    public func finish(at date: Date) { consume(.boundary(ActivityBoundary(timestamp: date))) }

    private func consume(_ input: SpanAggregator.Input) {
        let commands = aggregator.consume(input).flatMap(commands(for:))
        if !commands.isEmpty { writer.write(commands) }
    }

    private func commands(for output: SpanAggregator.Output) -> [ActivityRecordCommand] {
        switch output {
        case .sessionStarted:
            sessionOpen = true
            lastStoredEnd = nil
            return []
        case .sessionEnded:
            defer { sessionOpen = false; lastStoredEnd = nil }
            return lastStoredEnd.map { [.endSession($0)] } ?? []
        case let .activity(sample, end):
            // The rules as they are now: an app excluded meanwhile is dropped,
            // and, like a boundary, the dropped time ends the written session.
            guard let event = filter.event(from: sample, until: end, source: source) else {
                defer { lastStoredEnd = nil }
                return lastStoredEnd.map { [.endSession($0)] } ?? []
            }
            var commands: [ActivityRecordCommand] = []
            if sessionOpen, lastStoredEnd == nil { commands.append(.startSession(event.startedAt)) }
            if sessionOpen { lastStoredEnd = event.endedAt }
            commands.append(.insert(event))
            return commands
        case let .idle(interval):
            return [.insert(filter.idleEvent(from: interval.start, until: interval.end, source: source))]
        }
    }
}

/// The real ``ActivityRecordWriter``: applies commands to an
/// `ActivityRepository` on a private serial queue (repository calls block,
/// so never on the main actor), in the order they were written.
///
/// Activity events are assigned to the session opened before them; idle
/// events to none. If opening a session fails, its events are stored
/// without a session. If closing one fails, the close is kept and retried
/// before the next commands (not retried when the session no longer
/// exists). A session left open anyway (a crash, or a close still failing
/// at quit) keeps its row and its events' session IDs, which is what a
/// repair on launch needs; that repair belongs to app integration and
/// retention (#27). Errors go to `onError`, once per failure (not per
/// retry), which runs on the queue; they
/// come from SQLite, whose messages never include stored values
/// (`publicStatementArguments` is off), but do not log more than the error.
public final class RepositoryRecordWriter: ActivityRecordWriter, @unchecked Sendable {
    private let repository: any ActivityRepository
    private let onError: @Sendable (any Error) -> Void
    private let queue = DispatchQueue(label: "com.lemacarl.unreality.activity-writer")
    /// Accessed only on `queue`.
    private var sessionID: Int64?
    /// Session closes that failed, retried before the next commands. Only on `queue`.
    private var pendingCloses: [(id: Int64, end: Date)] = []

    public init(repository: any ActivityRepository, onError: @escaping @Sendable (any Error) -> Void = { _ in }) {
        self.repository = repository
        self.onError = onError
    }

    public func write(_ commands: [ActivityRecordCommand]) {
        queue.async { [self] in
            retryPendingCloses()
            for command in commands { apply(command) }
        }
    }

    /// Blocks until every command written so far has been applied. For
    /// tests and for quitting; never call it on the writer's own queue.
    public func waitUntilIdle() {
        queue.sync {}
    }

    private func apply(_ command: ActivityRecordCommand) {
        do {
            switch command {
            case let .startSession(date):
                sessionID = nil
                sessionID = try repository.startSession(at: date).id
            case let .insert(event):
                try repository.insert(event.kind == .idle ? event.inSession(nil) : event.inSession(sessionID))
            case let .endSession(date):
                guard let id = sessionID else { return }
                sessionID = nil
                close(id, at: date, report: true)
            }
        } catch {
            onError(error)
        }
    }

    private func close(_ id: Int64, at end: Date, report: Bool) {
        do {
            try repository.endSession(id: id, at: end)
        } catch {
            if error as? StorageError != .sessionNotFound(id) { pendingCloses.append((id, end)) }
            if report { onError(error) }
        }
    }

    private func retryPendingCloses() {
        let closes = pendingCloses
        pendingCloses = []
        for pending in closes { close(pending.id, at: pending.end, report: false) }
    }
}
