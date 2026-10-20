import Foundation
import Testing
import UnrealityCore

@Suite("ActivityRepository (GRDB, in-memory)")
struct ActivityRepositoryTests {
    // Whole seconds: dates are stored with millisecond precision.
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let repository: any ActivityRepository
    private var everything: DateInterval { DateInterval(start: base - 86_400, duration: 2 * 86_400) }

    init() throws {
        repository = try DatabaseManager.inMemory().activityRepository()
    }

    private func event(_ kind: ActivityEventKind = .app, from start: TimeInterval, to end: TimeInterval,
                       sessionID: Int64? = nil) throws -> FilteredEvent {
        // Storage takes only filtered events; the blocklist is irrelevant here.
        try #require(PrivacyFilter(blocklist: .empty).filter(ActivitySample(
            kind: kind,
            appBundleID: kind == .idle ? nil : "com.example.editor",
            windowTitle: kind == .idle ? nil : "notes.txt",
            url: kind == .web ? "https://example.com/" : nil,
            startedAt: base + start,
            endedAt: base + end,
            source: "test",
            sessionID: sessionID
        )))
    }

    @Test("insert assigns an id and round-trips every field", arguments: ActivityEventKind.allCases)
    func insertRoundTrip(_ kind: ActivityEventKind) throws {
        let original = try event(kind, from: 0, to: 30)
        let inserted = try repository.insert(original)
        #expect(inserted.id != nil)
        #expect(inserted == ActivityEvent(original, id: inserted.id))

        let fetched = try repository.events(overlapping: DateInterval(start: base, duration: 30))
        #expect(fetched == [inserted])
    }

    @Test("events(overlapping:) returns half-open overlaps, oldest first")
    func overlapQuery() throws {
        try repository.insert(event(from: 100, to: 200))
        try repository.insert(event(from: 0, to: 50))     // ends exactly at window start
        try repository.insert(event(from: 40, to: 60))    // straddles window start
        try repository.insert(event(from: 150, to: 160))  // starts exactly at window end
        let window = DateInterval(start: base + 50, end: base + 150)

        let fetched = try repository.events(overlapping: window)
        #expect(fetched.map(\.startedAt) == [base + 40, base + 100])
    }

    @Test("an event ending before it starts is rejected by the schema")
    func rejectsNegativeDuration() throws {
        #expect(throws: (any Error).self) {
            try repository.insert(event(from: 10, to: 5))
        }
        #expect(try repository.events(overlapping: everything).isEmpty)
    }

    @Test("an event cannot reference a missing session")
    func rejectsUnknownSession() throws {
        #expect(throws: (any Error).self) {
            try repository.insert(event(from: 0, to: 5, sessionID: 999))
        }
        #expect(try repository.events(overlapping: everything).isEmpty)
    }

    @Test("a session cannot end before it starts, and the rejected end is not written")
    func rejectsSessionEndingBeforeStart() throws {
        let session = try repository.startSession(at: base + 10)
        #expect(throws: (any Error).self) {
            try repository.endSession(id: try #require(session.id), at: base)
        }
        #expect(try repository.sessions(overlapping: everything) == [session])
    }

    @Test("ending an already-ended session overwrites its end")
    func reEndSession() throws {
        let session = try repository.startSession(at: base)
        let id = try #require(session.id)
        try repository.endSession(id: id, at: base + 10)
        try repository.endSession(id: id, at: base + 20)
        #expect(try repository.sessions(overlapping: everything)
            == [ActivitySession(id: id, startedAt: base, endedAt: base + 20)])
    }

    @Test("sessions start open, end, and are queried by overlap")
    func sessionLifecycle() throws {
        let closed = try repository.startSession(at: base)
        let closedID = try #require(closed.id)
        try repository.endSession(id: closedID, at: base + 100)
        let open = try repository.startSession(at: base + 200)
        #expect(open.endedAt == nil)

        let all = try repository.sessions(overlapping: DateInterval(start: base, duration: 10_000))
        #expect(all == [ActivitySession(id: closedID, startedAt: base, endedAt: base + 100), open])

        let later = try repository.sessions(overlapping: DateInterval(start: base + 5_000, duration: 10))
        #expect(later == [open])
    }

    @Test("ending a missing session throws sessionNotFound")
    func endMissingSession() {
        #expect(throws: StorageError.sessionNotFound(42)) {
            try repository.endSession(id: 42, at: base)
        }
    }

    @Test("deleteEvents(endedBefore:) removes only older events")
    func retentionDeletesEvents() throws {
        try repository.insert(event(from: 0, to: 10))
        try repository.insert(event(from: 20, to: 30))
        let kept = try repository.insert(event(from: 40, to: 50))

        #expect(try repository.deleteEvents(endedBefore: base + 40) == 2)
        let remaining = try repository.events(overlapping: DateInterval(start: base, duration: 100))
        #expect(remaining.map(\.id) == [kept.id])
    }

    @Test("deleteSessions(endedBefore:) keeps open sessions and detaches events")
    func retentionDeletesSessions() throws {
        let old = try repository.startSession(at: base)
        let oldID = try #require(old.id)
        try repository.endSession(id: oldID, at: base + 10)
        let open = try repository.startSession(at: base + 5)
        try repository.insert(event(from: 0, to: 10, sessionID: oldID))
        let window = DateInterval(start: base, duration: 100)
        #expect(try repository.events(overlapping: window).map(\.sessionID) == [oldID])

        #expect(try repository.deleteSessions(endedBefore: base + 1_000) == 1)
        #expect(try repository.sessions(overlapping: window) == [open])
        #expect(try repository.events(overlapping: window).map(\.sessionID) == [nil])
    }
}
