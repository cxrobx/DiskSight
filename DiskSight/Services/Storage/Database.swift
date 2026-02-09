import Foundation
import GRDB

final class Database: Sendable {
    static let shared = Database()

    let dbPool: DatabasePool

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("DiskSight", isDirectory: true)
        try! FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("disksight.sqlite").path

        var config = Configuration()
        #if DEBUG
        config.prepareDatabase { db in
            db.trace { print("SQL: \($0)") }
        }
        #endif

        dbPool = try! DatabasePool(path: dbPath, configuration: config)
        try! migrator.migrate(dbPool)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "scan_sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("root_path", .text).notNull()
                t.column("started_at", .double).notNull()
                t.column("completed_at", .double)
                t.column("file_count", .integer).defaults(to: 0)
                t.column("total_size", .integer).defaults(to: 0)
                t.column("last_fsevents_id", .integer)
            }

            try db.create(table: "files") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("parent_path", .text)
                t.column("size", .integer).notNull().defaults(to: 0)
                t.column("is_directory", .boolean).notNull().defaults(to: false)
                t.column("modified_at", .double)
                t.column("accessed_at", .double)
                t.column("created_at", .double)
                t.column("content_hash", .text)
                t.column("partial_hash", .text)
                t.column("file_type", .text)
                t.column("scan_session_id", .integer).references("scan_sessions")
            }

            try db.create(index: "idx_files_parent", on: "files", columns: ["parent_path"])
            try db.create(index: "idx_files_size", on: "files", columns: ["size"])
            try db.create(index: "idx_files_accessed", on: "files", columns: ["accessed_at"])
            try db.create(index: "idx_files_partial_hash", on: "files", columns: ["partial_hash"])
            try db.create(index: "idx_files_content_hash", on: "files", columns: ["content_hash"])

            try db.create(table: "cache_patterns") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pattern", .text).notNull()
                t.column("category", .text).notNull()
                t.column("safety", .text).notNull().defaults(to: "yellow")
                t.column("description", .text)
            }
        }

        return migrator
    }
}
