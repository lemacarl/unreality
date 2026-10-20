import Foundation
import Testing
import UnrealityCore

/// Records every event that reaches storage.
private final class RecordingRepository: ActivityRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ActivityEvent] = []

    var events: [ActivityEvent] { lock.withLock { stored } }

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
struct FilterBeforeStorageTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let sentinel = "unreality-excluded-\(UUID().uuidString)"
    private let filter = PrivacyFilter()

    /// Fixture capture: allowed activity interleaved with excluded apps and
    /// sites whose titles carry `sentinel`.
    private var fixture: [ActivitySample] {
        let excludedApps = ["com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess",
                            "com.apple.MobileSMS", "org.whispersystems.signal-desktop", "net.whatsapp.WhatsApp"]
        let excludedSites = ["https://www.paypal.com/summary", "https://my.1password.com/vaults",
                             "https://web.whatsapp.com/", "https://secure.chase.com/account?id=1"]
        var samples: [ActivitySample] = []
        var offset: TimeInterval = 0
        func add(_ kind: ActivityEventKind, _ app: String?, _ title: String?, _ url: String?) {
            samples.append(ActivitySample(kind: kind, appBundleID: app, windowTitle: title, url: url,
                                          startedAt: start + offset, endedAt: start + offset + 5, source: "fixture"))
            offset += 10
        }
        add(.app, "com.example.editor", "allowed-editor", nil)
        for app in excludedApps { add(.app, app, "\(sentinel) app", nil) }
        add(.web, "com.apple.Safari", "allowed-page", "https://example.com/docs?session=\(sentinel)")
        for url in excludedSites { add(.web, "com.apple.Safari", "\(sentinel) site", url) }
        add(.web, "com.apple.Safari", "\(sentinel) unparsable", "\(sentinel) not a url")
        add(.idle, nil, nil, nil)
        return samples
    }

    private func assertOnlyAllowed(_ events: [ActivityEvent]) {
        #expect(events.map(\.windowTitle) == ["allowed-editor", "allowed-page", nil])
        #expect(events.map(\.url) == [nil, "https://example.com/docs", nil])
        for event in events {
            #expect(!(event.windowTitle ?? "").contains(sentinel))
            #expect(!(event.url ?? "").contains(sentinel))
            #expect(!Blocklist.defaults.excludes(bundleID: event.appBundleID ?? ""))
        }
    }

    @Test("events from excluded apps and sites never reach the repository")
    func neverReachesRepository() throws {
        let repository = RecordingRepository()
        for sample in fixture {
            try repository.insert(sample, filteredBy: filter)
        }
        assertOnlyAllowed(repository.events)
    }

    @Test("nothing from excluded apps or sites is stored in the database")
    func nothingStoredInDatabase() throws {
        let repository = try DatabaseManager.inMemory().activityRepository()
        let results = try fixture.map { try repository.insert($0, filteredBy: filter) }
        #expect(results.compactMap(\.self).count == 3)
        let stored = try repository.events(overlapping: DateInterval(start: start - 1, duration: 10_000))
        assertOnlyAllowed(stored)
    }

    @Test("excluded activity leaves no trace in the database files")
    func nothingOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "unreality-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try DatabaseManager.open(in: directory).activityRepository()
        for sample in fixture {
            try repository.insert(sample, filteredBy: filter)
        }
        let path = directory.appending(path: DatabaseManager.fileName).path(percentEncoded: false)
        var sawFile = false
        for file in [path, path + "-wal"] where FileManager.default.fileExists(atPath: file) {
            sawFile = true
            let bytes = try Data(contentsOf: URL(filePath: file))
            #expect(bytes.range(of: Data(sentinel.utf8)) == nil, "\(file)")
            #expect(bytes.range(of: Data("paypal".utf8)) == nil, "\(file)")
        }
        #expect(sawFile)
        // Control: allowed text does reach disk, so the search above can find text.
        let all = try [path, path + "-wal"].filter { FileManager.default.fileExists(atPath: $0) }
            .map { try Data(contentsOf: URL(filePath: $0)) }
        #expect(all.contains { $0.range(of: Data("allowed-editor".utf8)) != nil })
    }

    @Test("database errors do not include statement arguments such as window titles")
    func errorsOmitArguments() throws {
        let repository = try DatabaseManager.inMemory().activityRepository()
        // Ends before it starts: rejected by the schema's CHECK constraint.
        let invalid = try #require(filter.filter(ActivitySample(
            kind: .app, appBundleID: "com.example.editor", windowTitle: sentinel,
            startedAt: start + 10, endedAt: start, source: "test"
        )))
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
