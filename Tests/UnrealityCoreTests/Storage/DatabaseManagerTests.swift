import Foundation
import Testing
import UnrealityCore

@Suite("DatabaseManager")
struct DatabaseManagerTests {
    private let files = FileManager.default
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryDirectory() -> URL {
        files.temporaryDirectory
            .appending(path: "unreality-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func mode(_ path: String) throws -> Int? {
        try files.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    }

    @Test("migrations run from empty on an in-memory database")
    func migratesInMemory() throws {
        let manager = try DatabaseManager.inMemory()
        #expect(try manager.appliedMigrations() == ["v1_events_sessions"])
    }

    @Test("a file-backed database is created, migrated once and persists across opens")
    func fileBackedPersists() throws {
        let directory = temporaryDirectory()
        defer { try? files.removeItem(at: directory) }

        let event = try TestEvents.event(.idle, from: start, to: start + 60)
        do {
            let manager = try DatabaseManager.open(in: directory)
            try manager.activityRepository().insert(event)
        }

        let path = directory.appending(path: DatabaseManager.fileName).path(percentEncoded: false)
        #expect(files.fileExists(atPath: path))
        #expect(try mode(directory.path(percentEncoded: false)) == 0o700)

        let reopened = try DatabaseManager.open(in: directory)
        #expect(try reopened.appliedMigrations() == ["v1_events_sessions"])
        let stored = try reopened.activityRepository()
            .events(overlapping: DateInterval(start: start, duration: 60))
        #expect(stored.count == 1)
        #expect(stored.first?.kind == .idle)
    }

    @Test("open tightens an existing folder to 0700 and the database files to 0600")
    func tightensPermissions() throws {
        let directory = temporaryDirectory()
        defer { try? files.removeItem(at: directory) }
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o755])

        let manager = try DatabaseManager.open(in: directory)
        try manager.activityRepository()
            .insert(TestEvents.event(.idle, from: start, to: start + 1))

        #expect(try mode(directory.path(percentEncoded: false)) == 0o700)
        let path = directory.appending(path: DatabaseManager.fileName).path(percentEncoded: false)
        for file in [path, path + "-wal", path + "-shm"] {
            #expect(try mode(file) == 0o600, "\(file)")
        }
    }

    @Test("retention deletes leave no copy of the deleted text in the database or its write-ahead log")
    func deletedTextIsGoneFromDisk() throws {
        let directory = temporaryDirectory()
        defer { try? files.removeItem(at: directory) }
        let manager = try DatabaseManager.open(in: directory)
        let repository = manager.activityRepository()
        let path = directory.appending(path: DatabaseManager.fileName).path(percentEncoded: false)
        let sentinel = "unreality-sentinel-\(UUID().uuidString)"
        func onDisk() throws -> Bool {
            try [path, path + "-wal"].contains { file in
                try Data(contentsOf: URL(filePath: file)).range(of: Data(sentinel.utf8)) != nil
            }
        }

        let session = try repository.startSession(at: start)
        try repository.endSession(id: try #require(session.id), at: start + 10)
        try repository.insert(TestEvents.event(.app, title: sentinel, from: start, to: start + 10,
                                               sessionID: session.id))
        #expect(try onDisk(), "control: the sentinel is written to disk before the delete")

        #expect(try repository.deleteEvents(endedBefore: start + 60) == 1)
        #expect(try repository.deleteSessions(endedBefore: start + 60) == 1)
        #expect(try !onDisk())
    }

    @Test("the default directory is the app's Application Support folder")
    func defaultDirectory() throws {
        let url = try DatabaseManager.defaultDirectory()
        #expect(url.lastPathComponent == AppIdentity.bundleIdentifier)
        #expect(url.deletingLastPathComponent().lastPathComponent == "Application Support")
    }
}
