import Foundation
import GRDB
import OSLog

struct DatabaseStartupIssue: Sendable {
    let title: String
    let message: String
}

final class Database: Sendable {
    private static let logger = Logger(subsystem: "com.disksight.app", category: "Database")
    static let shared = Database.makeShared()

    let dbPool: DatabasePool
    let databaseURL: URL
    let startupIssue: DatabaseStartupIssue?
    var storageDirectoryURL: URL { databaseURL.deletingLastPathComponent() }

    init(databaseURL: URL) throws {
        try Self.ensureParentDirectory(for: databaseURL)
        let dbPool = try Self.makeDatabasePool(at: databaseURL)
        try Self.configureVacuumMode(on: dbPool)
        try Self.migrator.migrate(dbPool)

        self.dbPool = dbPool
        self.databaseURL = databaseURL
        self.startupIssue = nil
    }

    private init(databaseURL: URL, dbPool: DatabasePool, startupIssue: DatabaseStartupIssue?) {
        self.dbPool = dbPool
        self.databaseURL = databaseURL
        self.startupIssue = startupIssue
    }

    private static func makeShared() -> Database {
        do {
            return try Database(databaseURL: defaultDatabaseURL())
        } catch {
            logger.error("Primary database startup failed: \(error.localizedDescription, privacy: .public)")
        }

        let databaseURL: URL
        do {
            databaseURL = try defaultDatabaseURL()
        } catch {
            return fallbackTemporaryDatabase(
                issue: DatabaseStartupIssue(
                    title: "Disk Index Reset",
                    message: "DiskSight could not access its Application Support database location. A temporary empty index was created for this launch."
                ),
                underlyingError: error
            )
        }

        do {
            let backupDirectory = try backupCorruptedDatabaseArtifacts(at: databaseURL)
            var recovered = try Database(databaseURL: databaseURL)
            recovered = Database(
                databaseURL: recovered.databaseURL,
                dbPool: recovered.dbPool,
                startupIssue: DatabaseStartupIssue(
                    title: "Disk Index Reset",
                    message: "DiskSight reset its local index after a startup failure. Run a fresh scan to rebuild results. Backup: \(backupDirectory.path)"
                )
            )
            logger.error("Recovered by resetting the database at \(databaseURL.path, privacy: .public)")
            return recovered
        } catch {
            logger.error("Database reset recovery failed: \(error.localizedDescription, privacy: .public)")
            return fallbackTemporaryDatabase(
                issue: DatabaseStartupIssue(
                    title: "Disk Index Recovery Failed",
                    message: "DiskSight could not reopen its local index. A temporary empty index was created for this launch. Run a fresh scan after restarting."
                ),
                underlyingError: error
            )
        }
    }

    private static func fallbackTemporaryDatabase(
        issue: DatabaseStartupIssue,
        underlyingError: Error
    ) -> Database {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSight-Recovery-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")

        do {
            let recovered = try Database(databaseURL: temporaryURL)
            logger.error("Using temporary recovery database at \(temporaryURL.path, privacy: .public)")
            return Database(
                databaseURL: recovered.databaseURL,
                dbPool: recovered.dbPool,
                startupIssue: issue
            )
        } catch {
            logger.fault("Temporary database fallback failed: \(error.localizedDescription, privacy: .public)")
            preconditionFailure("Unable to initialize DiskSight database: \(underlyingError.localizedDescription)")
        }
    }

    private static func defaultDatabaseURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return appSupport
            .appendingPathComponent("DiskSight", isDirectory: true)
            .appendingPathComponent("disksight.sqlite")
    }

    private static func ensureParentDirectory(for databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    static func isManagedStoragePath(_ path: String, databaseURL: URL) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let storagePath = databaseURL.deletingLastPathComponent().standardizedFileURL.path
        return normalizedPath == storagePath || normalizedPath.hasPrefix(storagePath + "/")
    }

    static func isLikelyPersistentStorageFailure(_ error: Error) -> Bool {
        if let error = error as? DatabaseError {
            switch error.resultCode.primaryResultCode {
            case .SQLITE_IOERR, .SQLITE_READONLY, .SQLITE_FULL, .SQLITE_CANTOPEN, .SQLITE_CORRUPT, .SQLITE_NOTADB:
                return true
            default:
                break
            }
        }

        return isLikelyPersistentStorageFailure(message: error.localizedDescription)
    }

    static func isLikelyPersistentStorageFailure(message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("disk i/o error")
            || normalized.contains("readonly database")
            || normalized.contains("database or disk is full")
            || normalized.contains("unable to open the database file")
            || normalized.contains("database disk image is malformed")
            || normalized.contains("not a database")
    }

    private static func makeDatabasePool(at databaseURL: URL) throws -> DatabasePool {
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

        return try DatabasePool(path: databaseURL.path, configuration: config)
    }

    private static func configureVacuumMode(on dbPool: DatabasePool) throws {
        try dbPool.write { db in
            // auto_vacuum can only be set on a new database (before tables exist).
            // On existing databases this is a harmless no-op.
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        }
    }

    private static func backupCorruptedDatabaseArtifacts(at databaseURL: URL) throws -> URL {
        let fm = FileManager.default
        let artifactPaths = [
            databaseURL.path,
            databaseURL.path + "-wal",
            databaseURL.path + "-shm"
        ]

        let existingArtifacts = artifactPaths.filter { fm.fileExists(atPath: $0) }
        guard !existingArtifacts.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }

        let backupDirectory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("Recovered-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        for artifact in existingArtifacts {
            let sourceURL = URL(fileURLWithPath: artifact)
            let destinationURL = backupDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: sourceURL, to: destinationURL)
        }

        return backupDirectory
    }

    private static var migrator: DatabaseMigrator {
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

        migrator.registerMigration("v9_growth_covering_index") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_files_growth
                ON files (created_at, parent_path, size)
                WHERE is_directory = 0 AND created_at IS NOT NULL
                """)
        }

        migrator.registerMigration("v10_export_paging_index") { db in
            try db.create(
                index: "idx_files_session_id",
                on: "files",
                columns: ["scan_session_id", "id"]
            )
        }

        migrator.registerMigration("v11_cleanup_llm_raised_confidence") { db in
            try db.alter(table: "cleanup_recommendations") { t in
                t.add(column: "llm_raised_confidence", .boolean).notNull().defaults(to: false)
            }
        }

        return migrator
    }
}
