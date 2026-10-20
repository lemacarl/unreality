import Foundation
import GRDB

/// What an `ActivityEvent` describes.
public enum ActivityEventKind: String, Codable, Sendable, CaseIterable {
    /// A frontmost app (and window) was in use.
    case app
    /// A browser tab was in use; `url` is set.
    case web
    /// The user was idle (no app attribution).
    case idle
}

/// One span of recorded activity. Stored in the `events` table.
///
/// Dates are stored as UTC text with millisecond precision.
public struct ActivityEvent: Codable, Sendable, Equatable, Identifiable {
    /// Row id; `nil` until inserted.
    public var id: Int64?
    public var kind: ActivityEventKind
    /// Frontmost app's bundle identifier; `nil` for idle spans.
    public var appBundleID: String?
    public var windowTitle: String?
    /// Browser URL, already redacted by the privacy filter; `nil` when not web.
    public var url: String?
    public var startedAt: Date
    /// Must not be earlier than `startedAt` (enforced by the schema).
    public var endedAt: Date
    /// The capture source that produced the event, for example `workspace`.
    public var source: String
    /// The session this event belongs to, if any.
    public var sessionID: Int64?

    public init(
        id: Int64? = nil,
        kind: ActivityEventKind,
        appBundleID: String? = nil,
        windowTitle: String? = nil,
        url: String? = nil,
        startedAt: Date,
        endedAt: Date,
        source: String,
        sessionID: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.appBundleID = appBundleID
        self.windowTitle = windowTitle
        self.url = url
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, url, source
        case appBundleID = "app_bundle_id", windowTitle = "window_title"
        case startedAt = "started_at", endedAt = "ended_at", sessionID = "session_id"
    }
}

/// A continuous stretch of tracked work. Stored in the `sessions` table.
public struct ActivitySession: Codable, Sendable, Equatable, Identifiable {
    /// Row id; `nil` until inserted.
    public var id: Int64?
    public var startedAt: Date
    /// `nil` while the session is still open.
    public var endedAt: Date?

    public init(id: Int64? = nil, startedAt: Date, endedAt: Date? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, startedAt = "started_at", endedAt = "ended_at"
    }
}

extension ActivityEvent: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "events"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension ActivitySession: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "sessions"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
