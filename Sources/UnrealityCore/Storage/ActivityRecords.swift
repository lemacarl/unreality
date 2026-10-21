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

/// One span of recorded activity, as read from the `events` table.
///
/// Dates are stored as UTC text with millisecond precision. This is the read
/// model: it cannot be inserted. Storage accepts only a ``FilteredEvent``
/// (``ActivityRepository/insert(_:)``), which only ``PrivacyFilter`` creates.
/// `description`, `debugDescription` and `dump` redact the window title and
/// URL.
public struct ActivityEvent: Codable, Sendable, Equatable, Identifiable {
    /// Row id; `nil` until inserted.
    public var id: Int64?
    public var kind: ActivityEventKind
    /// Frontmost app's bundle identifier; `nil` for idle spans.
    public var appBundleID: String?
    public var windowTitle: String?
    /// Browser URL, redacted by the privacy filter; `nil` when not web.
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

    /// The stored form of `filtered`, with row id `id`. For repository
    /// implementations (including fakes) returning an inserted event.
    public init(_ filtered: FilteredEvent, id: Int64?) {
        self.init(
            id: id,
            kind: filtered.kind,
            appBundleID: filtered.appBundleID,
            windowTitle: filtered.windowTitle,
            url: filtered.url,
            startedAt: filtered.startedAt,
            endedAt: filtered.endedAt,
            source: filtered.source,
            sessionID: filtered.sessionID
        )
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

// Read-only record: deliberately not `PersistableRecord`, so the only write
// path is `EventInsertRecord`, built from a `FilteredEvent`.
extension ActivityEvent: FetchableRecord, TableRecord {
    public static let databaseTableName = "events"
}

/// The row written for a `FilteredEvent`. Internal; the repository's insert
/// is its only user.
struct EventInsertRecord: Encodable, MutablePersistableRecord {
    static let databaseTableName = ActivityEvent.databaseTableName
    typealias CodingKeys = ActivityEvent.CodingKeys

    var id: Int64?
    let event: FilteredEvent

    init(_ event: FilteredEvent) { self.event = event }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(event.kind, forKey: .kind)
        try container.encode(event.appBundleID, forKey: .appBundleID)
        try container.encode(event.windowTitle, forKey: .windowTitle)
        try container.encode(event.url, forKey: .url)
        try container.encode(event.startedAt, forKey: .startedAt)
        try container.encode(event.endedAt, forKey: .endedAt)
        try container.encode(event.source, forKey: .source)
        try container.encode(event.sessionID, forKey: .sessionID)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension ActivitySession: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "sessions"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
