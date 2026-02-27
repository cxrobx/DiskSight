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
        config.prepareDatabase { db in
            // Limit WAL file growth — checkpoint every 1000 pages (~4MB)
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
            // Cap page cache to 4MB to bound memory usage
            try db.execute(sql: "PRAGMA cache_size = -4000")
            #if DEBUG
            db.trace { print("SQL: \($0)") }
            #endif
        }

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

        migrator.registerMigration("v2_smart_cleanup") { db in
            try db.create(table: "cleanup_recommendations") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("file_path", .text).notNull()
                t.column("file_name", .text).notNull()
                t.column("file_size", .integer).notNull().defaults(to: 0)
                t.column("category", .text).notNull()
                t.column("confidence", .text).notNull()
                t.column("explanation", .text).notNull()
                t.column("signals", .text).notNull().defaults(to: "[]")
                t.column("llm_enhanced", .boolean).notNull().defaults(to: false)
                t.column("scan_session_id", .integer).references("scan_sessions")
                t.column("created_at", .double).notNull()
            }

            try db.create(index: "idx_cleanup_session", on: "cleanup_recommendations", columns: ["scan_session_id"])
            try db.create(index: "idx_cleanup_confidence", on: "cleanup_recommendations", columns: ["confidence"])
            try db.create(index: "idx_cleanup_category", on: "cleanup_recommendations", columns: ["category"])
        }

        migrator.registerMigration("v3_files_session_directory_index") { db in
            try db.create(
                index: "idx_files_session_directory",
                on: "files",
                columns: ["scan_session_id", "is_directory"]
            )
        }

        migrator.registerMigration("v4_created_at_index") { db in
            try db.create(index: "idx_files_created_at", on: "files", columns: ["created_at"])
        }

        migrator.registerMigration("v5_parent_covering_index") { db in
            try db.create(
                index: "idx_files_parent_covering",
                on: "files",
                columns: ["parent_path", "is_directory", "path", "modified_at"]
            )
        }

        migrator.registerMigration("v6_session_stats") { db in
            try db.alter(table: "scan_sessions") { t in
                t.add(column: "indexed_size", .integer)
            }
            // Covering index for session-scoped fileCount/totalSize fallback queries
            try db.create(
                index: "idx_files_session_size",
                on: "files",
                columns: ["scan_session_id", "is_directory", "size"]
            )
        }

        migrator.registerMigration("v7_growth_cache") { db in
            try db.create(table: "growth_cache") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("scan_session_id", .integer).notNull().references("scan_sessions")
                t.column("period", .text).notNull()
                t.column("payload", .text).notNull()
                t.column("generated_at", .double).notNull()
            }

            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_growth_cache_session_period
                ON growth_cache(scan_session_id, period)
                """)
        }

        migrator.registerMigration("v8_growth_cache_version") { db in
            try db.alter(table: "growth_cache") { t in
                t.add(column: "cache_version", .integer).notNull().defaults(to: 1)
            }
        }

        return migrator
    }
}
