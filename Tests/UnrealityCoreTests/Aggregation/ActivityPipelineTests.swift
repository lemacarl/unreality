import Foundation
import Testing
import UnrealityCore

/// Records commands synchronously.
private final class RecordingWriter: ActivityRecordWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [ActivityRecordCommand] = []
    var commands: [ActivityRecordCommand] { lock.withLock { written } }
    func write(_ commands: [ActivityRecordCommand]) { lock.withLock { written += commands } }
}

/// In-memory repository whose calls can be made to fail.
private final class FlakyRepository: ActivityRepository, @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var stored: [ActivityEvent] = []
    private var storedSessions: [ActivitySession] = []
    private let failStart: Bool
    private var insertFailures: Int
    private var endFailures: Int

    /// `insertFailures` / `endFailures`: how many of those calls fail before they succeed.
    init(failStart: Bool = false, insertFailures: Int = 0, endFailures: Int = 0) {
        self.failStart = failStart
        self.insertFailures = insertFailures
        self.endFailures = endFailures
    }

    var events: [ActivityEvent] { lock.withLock { stored } }
    var allSessions: [ActivitySession] { lock.withLock { storedSessions } }

    func insert(_ event: FilteredEvent) throws -> ActivityEvent {
        try lock.withLock {
            if insertFailures > 0 {
                insertFailures -= 1
                throw Failure()
            }
            stored.append(ActivityEvent(event, id: Int64(stored.count + 1)))
            return stored[stored.count - 1]
        }
    }
    func events(overlapping interval: DateInterval) throws -> [ActivityEvent] { events }
    func startSession(at date: Date) throws -> ActivitySession {
        try lock.withLock {
            if failStart { throw Failure() }
            storedSessions.append(ActivitySession(id: Int64(storedSessions.count + 1), startedAt: date))
            return storedSessions[storedSessions.count - 1]
        }
    }
    func endSession(id: Int64, at date: Date) throws {
        try lock.withLock {
            if endFailures > 0 {
                endFailures -= 1
                throw Failure()
            }
            guard let index = storedSessions.firstIndex(where: { $0.id == id }) else {
                throw StorageError.sessionNotFound(id)
            }
            storedSessions[index].endedAt = date
        }
    }
    func sessions(overlapping interval: DateInterval) throws -> [ActivitySession] { allSessions }
    func deleteEvents(endedBefore cutoff: Date) throws -> Int { 0 }
    func deleteSessions(endedBefore cutoff: Date) throws -> Int { 0 }
}

private final class ErrorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var failures: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

@MainActor
@Suite("ActivityPipeline")
struct ActivityPipelineTests {
    private let sentinel = "unreality-excluded-\(UUID().uuidString)"
    private let vault = FrontmostApp(bundleID: "com.1password.1password", name: "1Password", processID: 300)
    private let everything = DateInterval(start: .distantPast, end: .distantFuture)

    private func seconds(_ date: Date) -> TimeInterval { date.timeIntervalSinceReferenceDate }

    /// Coordinator, filter and pipeline sharing one `PrivacyFilter` and a fake clock.
    @MainActor
    private struct Rig {
        let clock = FakeTime()
        let source: FakeActivitySource
        let store = CaptureStateStore()
        let trust: FakeAccessibilityTrust
        let filter = PrivacyFilter()
        let coordinator: ActivityCoordinator
        let pipeline: ActivityPipeline

        init(trust: AccessibilityTrustState, writer: any ActivityRecordWriter) {
            source = FakeActivitySource(clock: clock, frontmost: finder, title: "Downloads")
            self.trust = FakeAccessibilityTrust(state: trust)
            coordinator = ActivityCoordinator(
                source: source, captureState: store, trust: self.trust, filter: filter, clock: clock
            )
            pipeline = ActivityPipeline(
                filter: filter, writer: writer, source: "test", calendar: AggregationFixture.utc
            )
            coordinator.startSignals(pipeline.receive)
        }

        func advance(_ seconds: Int) { clock.advance(by: .seconds(seconds)) }
    }

    @Test("end to end: excluded, paused and idle time is never attributed to the previous app")
    func endToEnd() throws {
        let database = try DatabaseManager.inMemory()
        let repository = database.activityRepository()
        let errors = ErrorCounter()
        let writer = RepositoryRecordWriter(repository: repository) { _ in errors.increment() }
        let rig = Rig(trust: .notTrusted, writer: writer)

        rig.advance(10)
        rig.trust.state = .trusted
        rig.coordinator.refreshAccessibilityTrust() // second snapshot for the same app (#67), now with a title
        rig.advance(10)
        rig.source.activate(vault, title: "\(sentinel) Vault")
        rig.source.setTitle("\(sentinel) other item")
        rig.advance(30)
        rig.source.activate(editor, title: "notes.txt")
        rig.advance(10)
        rig.store.pause()
        rig.advance(40)
        rig.store.resume() // fresh snapshot of the editor
        rig.advance(10)
        rig.pipeline.idleStarted(at: rig.clock.now())
        rig.advance(90)
        rig.pipeline.idleEnded(at: rig.clock.now())
        rig.advance(30)
        rig.coordinator.stop()
        #expect(!rig.pipeline.hasPendingActivity)
        writer.waitUntilIdle()

        let events = try repository.events(overlapping: everything)
        #expect(events.map(\.kind) == [.app, .app, .app, .app, .idle, .app])
        #expect(events.map(\.appBundleID) == [
            "com.example.files", "com.example.files", "com.example.editor", "com.example.editor", nil,
            "com.example.editor"
        ])
        #expect(events.map(\.windowTitle) == [nil, "Downloads", "notes.txt", "notes.txt", nil, "notes.txt"])
        #expect(events.map { [seconds($0.startedAt), seconds($0.endedAt)] } == [
            [0, 10], [10, 20], [50, 60], [100, 110], [110, 200], [200, 230]
        ])
        for event in events {
            #expect(!(event.windowTitle ?? "").contains(sentinel))
            #expect(!Blocklist.defaults.excludes(bundleID: event.appBundleID ?? ""))
            #expect(event.source == "test")
        }

        let sessions = try repository.sessions(overlapping: everything)
        #expect(sessions.map { [seconds($0.startedAt), $0.endedAt.map(seconds)] } == [
            [0, 20], [50, 60], [100, 110], [200, 230]
        ])
        let sessionIDs = sessions.map(\.id)
        #expect(events.map(\.sessionID) == [
            sessionIDs[0], sessionIDs[0], sessionIDs[1], sessionIDs[2], nil, sessionIDs[3]
        ])
        #expect(errors.failures == 0)
    }

    @Test("events are built with the filter's live rules: an app excluded mid-span is not stored")
    func liveRules() {
        let writer = RecordingWriter()
        let rig = Rig(trust: .trusted, writer: writer)
        rig.advance(10)
        rig.source.activate(editor, title: "\(sentinel) draft")
        rig.advance(10)
        // The user excludes the editor while its span is open.
        rig.filter.rules.blocklist = .defaults.union(Blocklist(bundleIDPatterns: ["com.example.editor"]))
        rig.source.setTitle("\(sentinel) another draft") // no longer read at all
        rig.advance(10)
        rig.source.activate(finder, title: "Downloads")
        rig.advance(5)
        rig.coordinator.stop()

        let inserted = writer.commands.compactMap { command -> FilteredEvent? in
            if case let .insert(event) = command { return event }
            return nil
        }
        #expect(inserted.map(\.appBundleID) == ["com.example.files", "com.example.files"])
        #expect(inserted.map { [seconds($0.startedAt), seconds($0.endedAt)] } == [[0, 10], [30, 35]])
        #expect(inserted.allSatisfy { !($0.windowTitle ?? "").contains(sentinel) })
        // Sessions cover stored events only.
        let time = Date.init(timeIntervalSinceReferenceDate:)
        #expect(writer.commands.filter { if case .insert = $0 { false } else { true } } == [
            .startSession(time(0)), .endSession(time(10)), .startSession(time(30)), .endSession(time(35))
        ])
    }

    @Test("a session whose every event is dropped is not written")
    func noEmptySessions() {
        let writer = RecordingWriter()
        let rig = Rig(trust: .trusted, writer: writer)
        rig.advance(10)
        rig.filter.rules.blocklist = .defaults.union(Blocklist(bundleIDPatterns: ["com.example.files"]))
        rig.pipeline.finish(at: rig.clock.now())
        #expect(writer.commands.isEmpty)
    }

    @Test("the writer stores events without a session when sessions cannot be written")
    func sessionFailure() {
        let repository = FlakyRepository(failStart: true)
        let errors = ErrorCounter()
        let writer = RepositoryRecordWriter(repository: repository) { _ in errors.increment() }
        let rig = Rig(trust: .trusted, writer: writer)
        rig.advance(10)
        rig.pipeline.idleStarted(at: rig.clock.now())
        rig.advance(10)
        rig.pipeline.finish(at: rig.clock.now())
        writer.waitUntilIdle()
        #expect(repository.events.map(\.kind) == [.app, .idle])
        #expect(repository.events.map(\.sessionID) == [nil, nil])
        #expect(errors.failures == 1) // the start; the end is skipped without a session id
    }

    @Test("a failed insert is reported and later commands still apply")
    func insertFailure() {
        let repository = FlakyRepository(insertFailures: 1)
        let errors = ErrorCounter()
        let writer = RepositoryRecordWriter(repository: repository) { _ in errors.increment() }
        let rig = Rig(trust: .trusted, writer: writer)
        rig.advance(10)
        rig.source.activate(editor, title: "notes.txt") // the Files span 0-10 fails to insert
        rig.advance(10)
        rig.pipeline.finish(at: rig.clock.now())
        writer.waitUntilIdle()
        #expect(errors.failures == 1)
        #expect(repository.events.map(\.appBundleID) == ["com.example.editor"])
        #expect(repository.events.map(\.sessionID) == [1])
        #expect(repository.allSessions.map(\.endedAt) == [Date(timeIntervalSinceReferenceDate: 20)])
    }

    @Test("a failed session close is kept and retried with the next commands, and reported once")
    func endSessionFailure() {
        let repository = FlakyRepository(endFailures: 2)
        let errors = ErrorCounter()
        let writer = RepositoryRecordWriter(repository: repository) { _ in errors.increment() }
        let rig = Rig(trust: .trusted, writer: writer)
        let time = Date.init(timeIntervalSinceReferenceDate:)
        rig.advance(10)
        rig.store.pause() // closing session 1 fails
        rig.advance(10)
        rig.store.resume()
        rig.advance(10)
        rig.store.pause() // the retry of 1 fails again (not reported); closing session 2 succeeds
        writer.waitUntilIdle()
        #expect(errors.failures == 1)
        #expect(repository.allSessions.map(\.endedAt) == [nil, time(30)])
        // The open row and its events' session ID are what a repair on launch needs.
        #expect(repository.events.map(\.sessionID) == [1, 2])
        rig.advance(10)
        rig.store.resume()
        rig.advance(10)
        rig.coordinator.stop() // the retry now succeeds
        writer.waitUntilIdle()
        #expect(repository.allSessions.map(\.endedAt) == [time(10), time(30), time(50)])
        #expect(errors.failures == 1)
    }

    @Test("idle reported after a pause, a stop or an excluded app stores nothing",
          arguments: ["pause", "stop", "excluded"])
    func idleAfterBoundary(_ boundary: String) {
        let writer = RecordingWriter()
        let rig = Rig(trust: .trusted, writer: writer)
        rig.advance(10)
        switch boundary {
        case "pause": rig.store.pause()
        case "stop": rig.coordinator.stop()
        default: rig.source.activate(vault, title: "\(sentinel) Vault")
        }
        rig.advance(5)
        rig.pipeline.idleStarted(at: rig.clock.now())
        rig.advance(100)
        if boundary == "pause" { rig.store.resume() }
        if boundary == "excluded" { rig.source.activate(finder, title: "Downloads") }
        rig.pipeline.idleEnded(at: rig.clock.now())
        rig.pipeline.finish(at: rig.clock.now())
        let inserted = writer.commands.compactMap { command -> FilteredEvent? in
            if case let .insert(event) = command { return event }
            return nil
        }
        #expect(inserted.map(\.kind) == [.app])
        #expect(inserted.map { [seconds($0.startedAt), seconds($0.endedAt)] } == [[0, 10]])
    }

    @Test("replacing the sink while running gives the previous sink a final boundary")
    func replacedSink() {
        let first = RecordingWriter()
        let rig = Rig(trust: .trusted, writer: first)
        let second = RecordingWriter()
        let replacement = ActivityPipeline(
            filter: rig.filter, writer: second, source: "test", calendar: AggregationFixture.utc
        )
        rig.advance(10)
        rig.coordinator.startSignals(replacement.receive)
        #expect(!rig.pipeline.hasPendingActivity)
        #expect(first.commands.count == 3) // start, the Files span 0-10, end
        #expect(replacement.hasPendingActivity)
        rig.advance(5)
        rig.coordinator.stop()
        #expect(second.commands.count == 3)
    }
}
