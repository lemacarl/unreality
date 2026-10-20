import Foundation
import GRDB

/// Errors raised by `ActivityRepository` beyond SQLite's own.
public enum StorageError: Error, Equatable {
    /// No session has the given id.
    case sessionNotFound(Int64)
}

/// Reads and writes recorded activity. Calls are synchronous and thread-safe;
/// call them off the main actor.
public protocol ActivityRepository: Sendable {
    /// Inserts `event` and returns the stored event with its new `id`.
    ///
    /// Takes only a ``FilteredEvent``, which only ``PrivacyFilter`` creates,
    /// so excluded or unredacted activity cannot be stored by construction.
    @discardableResult
    func insert(_ event: FilteredEvent) throws -> ActivityEvent

    /// Events overlapping `interval` (half-open: `startedAt < end` and
    /// `endedAt > start`), oldest first. A zero-length event at exactly
    /// `interval.start`, or a zero-length `interval`, matches nothing.
    func events(overlapping interval: DateInterval) throws -> [ActivityEvent]

    /// Opens a session starting at `date`.
    func startSession(at date: Date) throws -> ActivitySession

    /// Closes session `id` at `date`. Ending an already-ended session
    /// overwrites its end. Throws `StorageError.sessionNotFound` for an
    /// unknown id, and a database error when `date` is before the start.
    func endSession(id: Int64, at date: Date) throws

    /// Sessions overlapping `interval` (half-open; open sessions extend to
    /// the future), oldest first.
    func sessions(overlapping interval: DateInterval) throws -> [ActivitySession]

    /// Retention hook: deletes events whose end is strictly before `cutoff`
    /// (an event spanning the cutoff stays), then truncates the write-ahead
    /// log so no copy of the deleted rows stays on disk.
    /// - Returns: the number of events deleted.
    @discardableResult
    func deleteEvents(endedBefore cutoff: Date) throws -> Int

    /// Retention hook: deletes closed sessions whose end is strictly before
    /// `cutoff`, then truncates the write-ahead log. Open sessions are never
    /// deleted. Remaining events of those sessions keep their rows with no
    /// session.
    /// - Returns: the number of sessions deleted.
    @discardableResult
    func deleteSessions(endedBefore cutoff: Date) throws -> Int
}

extension ActivityRepository {
    /// Runs `sample` through `filter` and stores the result, if any.
    /// - Returns: the stored event, or `nil` when the filter dropped the
    ///   sample (nothing is written).
    @discardableResult
    public func insert(_ sample: ActivitySample, filteredBy filter: PrivacyFilter) throws -> ActivityEvent? {
        guard let event = filter.filter(sample) else { return nil }
        return try insert(event)
    }
}

/// GRDB-backed `ActivityRepository`. Created by `DatabaseManager`.
struct GRDBActivityRepository: ActivityRepository {
    let writer: any DatabaseWriter

    /// Columns shared by `events` and `sessions`.
    private enum Columns {
        static let id = Column("id")
        static let startedAt = Column("started_at")
        static let endedAt = Column("ended_at")
    }

    func insert(_ event: FilteredEvent) throws -> ActivityEvent {
        let record = try writer.write { database in try EventInsertRecord(event).inserted(database) }
        return ActivityEvent(event, id: record.id)
    }

    func events(overlapping interval: DateInterval) throws -> [ActivityEvent] {
        try writer.read { database in
            try ActivityEvent
                .filter(Columns.startedAt < interval.end && Columns.endedAt > interval.start)
                .order(Columns.startedAt, Columns.id)
                .fetchAll(database)
        }
    }

    func startSession(at date: Date) throws -> ActivitySession {
        try writer.write { database in try ActivitySession(startedAt: date).inserted(database) }
    }

    func endSession(id: Int64, at date: Date) throws {
        try writer.write { database in
            let changed = try ActivitySession
                .filter(key: id)
                .updateAll(database, Columns.endedAt.set(to: date))
            guard changed > 0 else { throw StorageError.sessionNotFound(id) }
        }
    }

    func sessions(overlapping interval: DateInterval) throws -> [ActivitySession] {
        try writer.read { database in
            let stillOpenAtStart = Columns.endedAt == nil || Columns.endedAt > interval.start
            return try ActivitySession
                .filter(Columns.startedAt < interval.end && stillOpenAtStart)
                .order(Columns.startedAt, Columns.id)
                .fetchAll(database)
        }
    }

    func deleteEvents(endedBefore cutoff: Date) throws -> Int {
        let deleted = try writer.write { database in
            try ActivityEvent.filter(Columns.endedAt < cutoff).deleteAll(database)
        }
        try truncateWriteAheadLog()
        return deleted
    }

    func deleteSessions(endedBefore cutoff: Date) throws -> Int {
        let deleted = try writer.write { database in
            try ActivitySession.filter(Columns.endedAt != nil && Columns.endedAt < cutoff).deleteAll(database)
        }
        try truncateWriteAheadLog()
        return deleted
    }

    /// `secure_delete` zeroes deleted rows only in the main file; automatic
    /// (PASSIVE) checkpoints leave their copies in `-wal`. A TRUNCATE
    /// checkpoint copies the log back and empties it. The barrier waits for
    /// readers so the checkpoint is not blocked. No-op without a WAL.
    private func truncateWriteAheadLog() throws {
        try writer.barrierWriteWithoutTransaction { database in
            _ = try database.checkpoint(.truncate)
        }
    }
}
