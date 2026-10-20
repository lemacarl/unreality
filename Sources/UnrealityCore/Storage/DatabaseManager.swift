import Foundation
import GRDB

/// Owns the SQLite connection and applies migrations on open.
///
/// File-backed databases use a GRDB `DatabasePool` (WAL: concurrent reads,
/// serialised writes); in-memory databases (tests) use a `DatabaseQueue`.
/// Both are thread-safe, so the manager is `Sendable` and can be shared
/// across actors. See docs/ARCHITECTURE.md, "Storage".
public final class DatabaseManager: Sendable {
    /// File name of the database inside its directory.
    public static let fileName = "unreality.sqlite"

    let writer: any DatabaseWriter

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Migrations.migrator.migrate(writer)
    }

    /// Opens (creating if needed) the database file in `directory`.
    ///
    /// On every open the directory is made owner-only (0700) and the
    /// database, `-wal` and `-shm` files owner read/write (0600). The main
    /// file is created 0600 before SQLite opens it, and SQLite gives the
    /// `-wal` and `-shm` files it creates the main file's mode.
    /// - Parameter directory: injectable for tests; the app passes
    ///   `defaultDirectory()`.
    public static func open(in directory: URL) throws -> DatabaseManager {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
        let path = directory.appending(path: fileName).path(percentEncoded: false)
        if !files.fileExists(atPath: path) {
            // An empty file is a valid empty SQLite database.
            files.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let manager = try DatabaseManager(writer: DatabasePool(path: path, configuration: configuration()))
        for file in [path, path + "-wal", path + "-shm"] where files.fileExists(atPath: file) {
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        }
        return manager
    }

    /// A fresh, private in-memory database, migrated to the latest schema.
    public static func inMemory() throws -> DatabaseManager {
        try DatabaseManager(writer: DatabaseQueue(configuration: configuration()))
    }

    /// `~/Library/Application Support/<bundle identifier>`.
    public static func defaultDirectory() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: AppIdentity.bundleIdentifier, directoryHint: .isDirectory)
    }

    /// Identifiers of the migrations applied to this database, in order.
    public func appliedMigrations() throws -> [String] {
        try writer.read { try Migrations.migrator.appliedMigrations($0) }
    }

    /// Repository over this database.
    public func activityRepository() -> any ActivityRepository {
        GRDBActivityRepository(writer: writer)
    }

    private static func configuration() -> Configuration {
        var config = Configuration()
        config.label = AppIdentity.displayName
        // Keep statement arguments (window titles, URLs) out of GRDB error
        // messages and trace descriptions, which may end up in logs. This is
        // GRDB's default; it is set explicitly so it is never turned on.
        config.publicStatementArguments = false
        config.prepareDatabase { database in
            // Overwrite deleted content (retention, user deletes) with zeros.
            try database.execute(sql: "PRAGMA secure_delete = ON")
        }
        return config
    }
}
