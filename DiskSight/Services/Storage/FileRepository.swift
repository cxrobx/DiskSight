import Foundation
import GRDB

actor FileRepository {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    // MARK: - Scan Sessions

    func createScanSession(rootPath: String) throws -> ScanSession {
        try database.dbPool.write { db in
            var session = ScanSession(
                rootPath: rootPath,
                startedAt: Date().timeIntervalSince1970
            )
            try session.insert(db)
            return session
        }
    }

    func completeScanSession(id: Int64) throws {
        try database.dbPool.write { db in
            let stats = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) as count, COALESCE(SUM(size), 0) as total
                FROM files WHERE scan_session_id = ?
                """, arguments: [id])

            try db.execute(sql: """
                UPDATE scan_sessions
                SET completed_at = ?, file_count = ?, total_size = ?
                WHERE id = ?
                """, arguments: [
                    Date().timeIntervalSince1970,
                    stats?["count"] ?? 0,
                    stats?["total"] ?? 0,
                    id
                ])
        }
    }

    func latestScanSession() throws -> ScanSession? {
        try database.dbPool.read { db in
            try ScanSession
                .order(Column("started_at").desc)
                .fetchOne(db)
        }
    }

    // MARK: - File Operations

    func insertFilesBatch(_ files: [FileNode]) throws {
        try database.dbPool.write { db in
            for var file in files {
                try file.insert(db, onConflict: .replace)
            }
        }
    }

    func deleteAllFiles() throws {
        try database.dbPool.write { db in
            try FileNode.deleteAll(db)
        }
    }

    func fileCount() throws -> Int {
        try database.dbPool.read { db in
            try FileNode.fetchCount(db)
        }
    }

    func totalSize() throws -> Int64 {
        try database.dbPool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) as total FROM files WHERE is_directory = 0")
            return row?["total"] ?? 0
        }
    }

    func topFolders(parentPath: String?, limit: Int = 10) throws -> [FileNode] {
        try database.dbPool.read { db in
            if let parentPath = parentPath {
                return try FileNode
                    .filter(Column("parent_path") == parentPath)
                    .filter(Column("is_directory") == true)
                    .order(Column("size").desc)
                    .limit(limit)
                    .fetchAll(db)
            } else {
                return try FileNode
                    .filter(Column("is_directory") == true)
                    .filter(Column("parent_path") == nil)
                    .order(Column("size").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        }
    }

    func children(ofPath path: String) throws -> [FileNode] {
        try database.dbPool.read { db in
            try FileNode
                .filter(Column("parent_path") == path)
                .order(Column("size").desc)
                .fetchAll(db)
        }
    }

    func calculateDirectorySizes() throws {
        try database.dbPool.write { db in
            try db.execute(sql: """
                UPDATE files SET size = (
                    SELECT COALESCE(SUM(f2.size), 0)
                    FROM files f2
                    WHERE f2.parent_path = files.path AND f2.is_directory = 0
                ) WHERE is_directory = 1
                """)
        }
    }

    // MARK: - Visualization Queries

    func rootNode() throws -> FileNode? {
        try database.dbPool.read { db in
            try FileNode
                .filter(Column("parent_path") == nil)
                .fetchOne(db)
        }
    }

    func childrenWithSizes(ofPath path: String) throws -> [FileNode] {
        try database.dbPool.read { db in
            try FileNode
                .filter(Column("parent_path") == path)
                .filter(Column("size") > 0)
                .order(Column("size").desc)
                .fetchAll(db)
        }
    }

    func largestFiles(limit: Int = 20) throws -> [FileNode] {
        try database.dbPool.read { db in
            try FileNode
                .filter(Column("is_directory") == false)
                .order(Column("size").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func fileTypeDistribution() throws -> [(String, Int64)] {
        try database.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT file_type, SUM(size) as total_size
                FROM files
                WHERE is_directory = 0 AND file_type IS NOT NULL
                GROUP BY file_type
                ORDER BY total_size DESC
                LIMIT 10
                """)
            return rows.map { ($0["file_type"] as String? ?? "unknown", $0["total_size"] as Int64? ?? 0) }
        }
    }
}
