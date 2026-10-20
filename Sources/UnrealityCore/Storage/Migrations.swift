import GRDB

/// Schema migrations, applied in order by `DatabaseManager`.
///
/// Never edit or reorder a migration that has shipped: add a new one. The
/// schema is documented in docs/ARCHITECTURE.md, "Storage".
enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_events_sessions", migrate: createEventsAndSessions)
        return migrator
    }

    private static func createEventsAndSessions(_ database: Database) throws {
        try database.create(table: "sessions") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("started_at", .datetime).notNull().indexed()
            table.column("ended_at", .datetime)
            table.check(sql: "ended_at IS NULL OR ended_at >= started_at")
        }
        // `kind` is validated by the Swift enum rather than a CHECK, so new
        // kinds do not need a table rebuild.
        try database.create(table: "events") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("kind", .text).notNull()
            table.column("app_bundle_id", .text)
            table.column("window_title", .text)
            table.column("url", .text)
            table.column("started_at", .datetime).notNull().indexed()
            table.column("ended_at", .datetime).notNull().indexed()
            table.column("source", .text).notNull()
            table.column("session_id", .integer)
                .references("sessions", onDelete: .setNull)
                .indexed()
            table.check(sql: "ended_at >= started_at")
        }
    }
}
