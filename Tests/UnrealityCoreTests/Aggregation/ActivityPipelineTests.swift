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

/// Repository whose session calls fail.
private final class FailingSessionRepository: ActivityRepository, @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var stored: [ActivityEvent] = []
    var events: [ActivityEvent] { lock.withLock { stored } }

    func insert(_ event: FilteredEvent) throws -> ActivityEvent {
        lock.withLock {
            stored.append(ActivityEvent(event, id: Int64(stored.count + 1)))
            return stored[stored.count - 1]
        }
    }
    func events(overlapping interval: DateInterval) throws -> [ActivityEvent] { events }
    func startSession(at date: Date) throws -> ActivitySession { throw Failure() }
    func endSession(id: Int64, at date: Date) throws { throw Failure() }
    func sessions(overlapping interval: DateInterval) throws -> [ActivitySession] { [] }
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
        let repository = FailingSessionRepository()
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
}
