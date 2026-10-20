import Foundation
import Testing
import UnrealityCore

/// Records every event that reaches storage.
private final class RecordingRepository: ActivityRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ActivityEvent] = []

    var events: [ActivityEvent] { lock.withLock { stored } }

    @discardableResult
    func insert(_ event: FilteredEvent) throws -> ActivityEvent {
        lock.withLock {
            let inserted = ActivityEvent(event, id: Int64(stored.count + 1))
            stored.append(inserted)
            return inserted
        }
    }

    func events(overlapping interval: DateInterval) throws -> [ActivityEvent] { events }
    func startSession(at date: Date) throws -> ActivitySession { ActivitySession(id: 1, startedAt: date) }
    func endSession(id: Int64, at date: Date) throws {}
    func sessions(overlapping interval: DateInterval) throws -> [ActivitySession] { [] }
    func deleteEvents(endedBefore cutoff: Date) throws -> Int { 0 }
    func deleteSessions(endedBefore cutoff: Date) throws -> Int { 0 }
}

@Suite("Privacy filter before storage")
@MainActor
struct FilterBeforeStorageTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let sentinel = "unreality-excluded-\(UUID().uuidString)"
    private let rules = PrivacyRules()

    private static let excludedApps = [
        "com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.apple.MobileSMS", "org.whispersystems.signal-desktop", "net.whatsapp.WhatsApp"
    ]
    private static let excludedSites = [
        "https://www.paypal.com/summary", "https://my.1password.com/vaults",
        "https://web.whatsapp.com/", "https://secure.chase.com/account?id=1"
    ]

    private func app(_ bundleID: String, _ pid: Int32) -> FrontmostApp {
        FrontmostApp(bundleID: bundleID, name: nil, processID: pid)
    }

    /// Fixture activity: allowed spans interleaved with excluded apps and
    /// sites whose titles carry `sentinel`. Each entry is a sample and its
    /// URL (for browser spans); each span lasts 5 seconds.
    private var fixture: [(sample: ActivitySample, url: String?)] {
        var entries: [(ActivitySample, String?)] = []
        var offset: TimeInterval = 0
        func add(_ bundleID: String, _ title: String?, _ url: String? = nil) {
            let sample = ActivitySample(timestamp: start + offset, trigger: .appActivated,
                                        app: app(bundleID, Int32(entries.count + 100)), windowTitle: title)
            entries.append((sample, url))
            offset += 10
        }
        add("com.example.editor", "allowed-editor")
        for bundleID in Self.excludedApps {
            add(bundleID, "\(sentinel) app")
            add(bundleID, nil) // app-only sample
        }
        add("com.apple.Safari", "allowed-page", "https://example.com/docs?session=\(sentinel)")
        for url in Self.excludedSites { add("com.apple.Safari", "\(sentinel) site", url) }
        add("com.apple.Safari", "\(sentinel) unparsable", "\(sentinel) not a url")
        return entries
    }

    private func storeFixture(in repository: any ActivityRepository) throws {
        for entry in fixture {
            let end = entry.sample.timestamp + 5
            if let event = rules.event(from: entry.sample, until: end, url: entry.url, source: "fixture") {
                try repository.insert(event)
            }
        }
        try repository.insert(rules.idleEvent(from: start + 1_000, until: start + 1_060, source: "fixture"))
    }

    private func assertOnlyAllowed(_ events: [ActivityEvent]) {
        #expect(events.map(\.windowTitle) == ["allowed-editor", "allowed-page", nil])
        #expect(events.map(\.url) == [nil, "https://example.com/docs", nil])
        #expect(events.map(\.kind) == [.app, .web, .idle])
        for event in events {
            #expect(!(event.windowTitle ?? "").contains(sentinel))
            #expect(!(event.url ?? "").contains(sentinel))
            #expect(!Blocklist.defaults.excludes(bundleID: event.appBundleID ?? ""))
        }
    }

    @Test("samples from excluded apps never leave the coordinator, so never reach the repository")
    func coordinatorToRepository() throws {
        let source = FakeActivitySource(frontmost: app("com.example.editor", 10), title: "allowed-editor")
        let filter = PrivacyFilter()
        let coordinator = ActivityCoordinator(
            source: source, captureState: CaptureStateStore(),
            trust: FakeAccessibilityTrust(state: .trusted), filter: filter
        )
        let repository = RecordingRepository()
        var pending: ActivitySample?
        func close(at end: Date) throws {
            if let previous = pending, let event = filter.rules.event(from: previous, until: end, source: "fixture") {
                try repository.insert(event)
            }
        }
        var failure: (any Error)?
        coordinator.start { sample in
            do { try close(at: sample.timestamp) } catch { failure = error }
            pending = sample
        }
        for (index, bundleID) in Self.excludedApps.enumerated() {
            source.activate(app(bundleID, Int32(20 + index)), title: "\(sentinel) app")
            source.setTitle("\(sentinel) changed")
        }
        source.activate(app("com.example.other", 30), title: "allowed-other")
        try close(at: .now)
        coordinator.stop()
        #expect(failure == nil)

        #expect(repository.events.map(\.appBundleID) == ["com.example.editor", "com.example.other"])
        #expect(repository.events.map(\.windowTitle) == ["allowed-editor", "allowed-other"])
        // The filter was asked about every excluded app before any title read, and said no.
        #expect(Set(source.titlePolicyQueries.compactMap(\.bundleID)).isSuperset(of: Self.excludedApps))
    }

    @Test("events from excluded apps and sites never reach the repository")
    func neverReachesRepository() throws {
        let repository = RecordingRepository()
        try storeFixture(in: repository)
        assertOnlyAllowed(repository.events)
    }

    @Test("nothing from excluded apps or sites is stored in the database")
    func nothingStoredInDatabase() throws {
        let repository = try DatabaseManager.inMemory().activityRepository()
        try storeFixture(in: repository)
        assertOnlyAllowed(try repository.events(overlapping: DateInterval(start: start - 1, duration: 10_000)))
    }

    @Test("excluded activity leaves no trace in the database files")
    func nothingOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "unreality-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try storeFixture(in: DatabaseManager.open(in: directory).activityRepository())
        let path = directory.appending(path: DatabaseManager.fileName).path(percentEncoded: false)
        let contents = try [path, path + "-wal"].filter { FileManager.default.fileExists(atPath: $0) }
            .map { try Data(contentsOf: URL(filePath: $0)) }
        #expect(!contents.isEmpty)
        for bytes in contents {
            #expect(bytes.range(of: Data(sentinel.utf8)) == nil)
            #expect(bytes.range(of: Data("paypal".utf8)) == nil)
        }
        // Control: allowed text does reach disk, so the search above can find text.
        #expect(contents.contains { $0.range(of: Data("allowed-editor".utf8)) != nil })
    }

    @Test("database errors do not include statement arguments such as window titles")
    func errorsOmitArguments() throws {
        let repository = try DatabaseManager.inMemory().activityRepository()
        // Ends before it starts: rejected by the schema's CHECK constraint.
        let invalid = try #require(rules.event(
            from: ActivitySample(timestamp: start + 10, trigger: .snapshot,
                                 app: app("com.example.editor", 1), windowTitle: sentinel),
            until: start, source: "test"
        ))
        do {
            try repository.insert(invalid)
            Issue.record("expected the insert to fail")
        } catch {
            #expect(!String(describing: error).contains(sentinel))
            #expect(!String(reflecting: error).contains(sentinel))
            #expect(!error.localizedDescription.contains(sentinel))
        }
    }
}
