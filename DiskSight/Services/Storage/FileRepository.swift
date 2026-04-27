import Foundation
import GRDB

actor FileRepository {
    private let database: Database
    private let growthCacheVersion = 3

    init(database: Database) {
        self.database = database
    }

    nonisolated var managedStorageDirectoryPath: String {
        database.storageDirectoryURL.standardizedFileURL.path
    }

    nonisolated func isManagedStoragePath(_ path: String) -> Bool {
        Database.isManagedStoragePath(path, databaseURL: database.databaseURL)
    }

    /// Bytes used on disk by the SQLite triplet (.sqlite + -wal + -shm).
    nonisolated func databaseFileSizeBytes() -> Int64 {
        let basePath = database.databaseURL.path
        return [basePath, basePath + "-wal", basePath + "-shm"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber }
            .map { $0.int64Value }
            .reduce(0, +)
    }

    /// Bytes that VACUUM could currently reclaim (free pages × page size).
    nonisolated func databaseFreeBytes() throws -> Int64 {
        try database.dbPool.read { db in
            let pageSize = Int64(try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0)
            let freelistCount = Int64(try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0)
            return pageSize * freelistCount
        }
    }

    // MARK: - Scan Sessions

    func createScanSession(rootPath: String) throws -> ScanSession {
        try database.dbPool.write { db in
            var session = ScanSession(
                rootPath: rootPath,
                startedAt: Date().timeIntervalSince1970
            )
            try session.insert(db)
            // Ensure id is set even if didInsert callback didn't fire
            if session.id == nil {
                session.id = db.lastInsertedRowID
            }
            return session
        }
    }

    func completeScanSession(id: Int64) throws {
        try database.dbPool.write { db in
            let stats = try Row.fetchOne(db, sql: """
                SELECT
                  COUNT(CASE WHEN is_directory = 0 THEN 1 END) as count,
                  COALESCE(SUM(size), 0) as total,
                  COALESCE(SUM(CASE WHEN is_directory = 0 THEN size ELSE 0 END), 0) as indexed
                FROM files WHERE scan_session_id = ?
                """, arguments: [id])

            try db.execute(sql: """
                UPDATE scan_sessions
                SET completed_at = ?, file_count = ?, total_size = ?, indexed_size = ?
                WHERE id = ?
                """, arguments: [
                    Date().timeIntervalSince1970,
                    stats?["count"] ?? 0,
                    stats?["total"] ?? 0,
                    stats?["indexed"] ?? 0,
                    id
                ])
        }
    }

    nonisolated func latestScanSession() throws -> ScanSession? {
        try database.dbPool.read { db in
            try ScanSession
                .order(Column("started_at").desc)
                .fetchOne(db)
        }
    }

    nonisolated func latestCompletedScanSession() throws -> ScanSession? {
        try database.dbPool.read { db in
            try ScanSession
                .filter(Column("completed_at") != nil)
                .order(Column("started_at").desc)
                .fetchOne(db)
        }
    }

    func deleteFilesFromPreviousSessions(currentSessionId: Int64) throws {
        try database.dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM files WHERE scan_session_id != ?",
                arguments: [currentSessionId]
            )
        }
    }

    func deleteOldSessions(keepingId: Int64) throws {
        try database.dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM scan_sessions WHERE id != ?",
                arguments: [keepingId]
            )
        }
    }

    func deleteIndexedPaths(inExcludedRoots roots: [String]) throws -> Int {
        let uniqueRoots = Array(Set(roots))
        guard !uniqueRoots.isEmpty else { return 0 }

        return try database.dbPool.write { db in
            var deletedCount = 0
            for root in uniqueRoots {
                deletedCount += try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM files
                        WHERE path = ?1
                           OR (length(path) > length(?1) AND substr(path, 1, length(?1) + 1) = ?1 || '/')
                        """,
                    arguments: [root]
                ) ?? 0

                try db.execute(
                    sql: """
                        DELETE FROM files
                        WHERE path = ?1
                           OR (length(path) > length(?1) AND substr(path, 1, length(?1) + 1) = ?1 || '/')
                        """,
                    arguments: [root]
                )
            }
            return deletedCount
        }
    }

    func compactIfNeeded(
        minimumFreeBytes: Int64 = 64 * 1024 * 1024,
        minimumFreeRatio: Double = 0.20,
        minimumWALBytes: Int64 = 64 * 1024 * 1024
    ) throws -> Bool {
        let walURL = URL(fileURLWithPath: database.databaseURL.path + "-wal")
        let walBytes = (try? walURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        var didWork = false
        if walBytes >= minimumWALBytes {
            try database.dbPool.barrierWriteWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            didWork = true
        }

        let stats = try database.dbPool.read { db in
            let pageSize = Int64(try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0)
            let pageCount = Int64(try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0)
            let freelistCount = Int64(try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0)
            return (pageSize, pageCount, freelistCount)
        }

        let freeBytes = stats.0 * stats.2
        let totalBytes = stats.0 * stats.1
        let freeRatio = totalBytes > 0 ? Double(freeBytes) / Double(totalBytes) : 0
        guard freeBytes >= minimumFreeBytes || freeRatio >= minimumFreeRatio else {
            return didWork
        }

        try database.dbPool.barrierWriteWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }

        return true
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

    nonisolated func fileCount() throws -> Int {
        try database.dbPool.read { db in
            try FileNode.fetchCount(db)
        }
    }

    nonisolated func totalSize() throws -> Int64 {
        try database.dbPool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) as total FROM files WHERE is_directory = 0")
            return row?["total"] ?? 0
        }
    }

    /// Session-scoped non-directory file count. Uses idx_files_session_size covering index.
    nonisolated func fileCount(sessionId: Int64) throws -> Int {
        try database.dbPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM files
                WHERE scan_session_id = ? AND is_directory = 0
                """, arguments: [sessionId]) ?? 0
        }
    }

    /// Session-scoped total size of non-directory files. Uses idx_files_session_size covering index.
    nonisolated func totalSize(sessionId: Int64) throws -> Int64 {
        try database.dbPool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(size), 0) as total
                FROM files WHERE scan_session_id = ? AND is_directory = 0
                """, arguments: [sessionId])
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
            // Multi-pass bottom-up propagation:
            // Pass 1: each directory = sum of immediate file children
            // Pass 2+: each directory = sum of ALL immediate children (files + subdirs)
            // Repeat until sizes stabilize (propagates from leaves to root)

            // First pass: sum only immediate file children
            try db.execute(sql: """
                UPDATE files SET size = (
                    SELECT COALESCE(SUM(f2.size), 0)
                    FROM files f2
                    WHERE f2.parent_path = files.path AND f2.is_directory = 0
                ) WHERE is_directory = 1
                """)

            // Subsequent passes: sum ALL immediate children (files + dirs with updated sizes)
            // Each pass propagates sizes up one level
            var previousRootSize: Int64 = -1
            for _ in 0..<30 { // max 30 levels deep
                let rootSize = try Int64.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(size), 0) FROM files WHERE parent_path IS NULL
                    """) ?? 0
                if rootSize == previousRootSize { break }
                previousRootSize = rootSize

                try db.execute(sql: """
                    UPDATE files SET size = (
                        SELECT COALESCE(SUM(f2.size), 0)
                        FROM files f2
                        WHERE f2.parent_path = files.path
                    ) WHERE is_directory = 1
                    """)
            }
        }
    }

    // MARK: - Visualization Queries

    func rootNode() throws -> FileNode? {
        try database.dbPool.read { db in
            // Primary: parent_path IS NULL (normal case)
            // Fallback: parent_path can be empty string or "/.." depending on scan path
            try FileNode
                .filter(Column("parent_path") == nil)
                .fetchOne(db)
            ?? FileNode
                .filter(Column("parent_path") == "")
                .filter(Column("is_directory") == true)
                .fetchOne(db)
            ?? FileNode
                .filter(Column("parent_path") == "/..")
                .filter(Column("is_directory") == true)
                .fetchOne(db)
        }
    }

    func directoryChildren(ofPath path: String) throws -> [FileNode] {
        try database.dbPool.read { db in
            try FileNode
                .filter(Column("parent_path") == path)
                .filter(Column("is_directory") == true)
                .filter(Column("size") > 0)
                .order(Column("size").desc)
                .fetchAll(db)
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

    // MARK: - Duplicate Detection

    func sizeMatchedFiles(minSize: Int64 = 1024) throws -> [[FileNode]] {
        try database.dbPool.read { db in
            let sizes = try Row.fetchAll(db, sql: """
                SELECT size FROM files
                WHERE is_directory = 0 AND size >= ?
                GROUP BY size HAVING COUNT(*) > 1
                """, arguments: [minSize])

            var groups: [[FileNode]] = []
            for row in sizes {
                let size: Int64 = row["size"]
                let files = try FileNode
                    .filter(Column("is_directory") == false)
                    .filter(Column("size") == size)
                    .fetchAll(db)
                if files.count > 1 {
                    groups.append(files)
                }
            }
            return groups
        }
    }

    func updatePartialHash(path: String, hash: String) throws {
        try database.dbPool.write { db in
            try db.execute(sql: "UPDATE files SET partial_hash = ? WHERE path = ?", arguments: [hash, path])
        }
    }

    func updateContentHash(path: String, hash: String) throws {
        try database.dbPool.write { db in
            try db.execute(sql: "UPDATE files SET content_hash = ? WHERE path = ?", arguments: [hash, path])
        }
    }

    func partialHashMatchedFiles() throws -> [[FileNode]] {
        try database.dbPool.read { db in
            let hashes = try Row.fetchAll(db, sql: """
                SELECT partial_hash FROM files
                WHERE is_directory = 0 AND partial_hash IS NOT NULL
                GROUP BY partial_hash HAVING COUNT(*) > 1
                """)

            var groups: [[FileNode]] = []
            for row in hashes {
                let hash: String = row["partial_hash"]
                let files = try FileNode
                    .filter(Column("is_directory") == false)
                    .filter(Column("partial_hash") == hash)
                    .fetchAll(db)
                if files.count > 1 {
                    groups.append(files)
                }
            }
            return groups
        }
    }

    func duplicateGroups(limit: Int = 100) throws -> [DuplicateGroup] {
        try database.dbPool.read { db in
            let hashes = try Row.fetchAll(db, sql: """
                SELECT content_hash, size FROM files
                WHERE is_directory = 0 AND content_hash IS NOT NULL
                GROUP BY content_hash HAVING COUNT(*) > 1
                ORDER BY size * COUNT(*) DESC
                LIMIT ?
                """, arguments: [limit])

            var groups: [DuplicateGroup] = []
            for row in hashes {
                let hash: String = row["content_hash"]
                let size: Int64 = row["size"]
                let files = try FileNode
                    .filter(Column("is_directory") == false)
                    .filter(Column("content_hash") == hash)
                    .fetchAll(db)
                if files.count > 1 {
                    groups.append(DuplicateGroup(id: hash, files: files, fileSize: size))
                }
            }
            return groups
        }
    }

    /// Returns paths of all files in a scan session that are duplicates
    /// (share a content_hash with another file in the same session).
    /// SQL-only — avoids loading full FileNode/DuplicateGroup objects into memory.
    func duplicateFilePaths(forSession sessionId: Int64) throws -> Set<String> {
        try database.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT path FROM files
                WHERE scan_session_id = ?
                  AND is_directory = 0
                  AND content_hash IN (
                    SELECT content_hash FROM files
                    WHERE scan_session_id = ?
                      AND is_directory = 0
                      AND content_hash IS NOT NULL
                    GROUP BY content_hash HAVING COUNT(*) > 1
                )
                """, arguments: [sessionId, sessionId])
            return Set(rows.compactMap { $0["path"] as String? })
        }
    }

    /// Returns paths of stale files in a scan session matching the given criteria.
    /// SQL-only — avoids loading full FileNode objects into memory.
    func staleFilePaths(
        forSession sessionId: Int64,
        accessedBefore cutoff: Double,
        minSize: Int64 = 1_048_576
    ) throws -> Set<String> {
        try database.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT path FROM files
                WHERE scan_session_id = ?
                  AND is_directory = 0
                  AND accessed_at IS NOT NULL
                  AND accessed_at < ?
                  AND size >= ?
                """, arguments: [sessionId, cutoff, minSize])
            return Set(rows.compactMap { $0["path"] as String? })
        }
    }

    /// Returns paths of files in a scan session matching any of the given LIKE patterns (cache detection).
    /// SQL-only — avoids loading full CacheDetector pipeline.
    func cacheMatchingPaths(forSession sessionId: Int64, patterns: [String]) throws -> Set<String> {
        guard !patterns.isEmpty else { return [] }
        return try database.dbPool.read { db in
            var paths = Set<String>()
            for pattern in patterns {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT path FROM files
                    WHERE scan_session_id = ?
                      AND path LIKE ?
                      AND is_directory = 0
                    """, arguments: [sessionId, pattern])
                for row in rows {
                    if let path: String = row["path"] {
                        paths.insert(path)
                    }
                }
            }
            return paths
        }
    }

    func deleteFile(path: String) throws {
        try database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM files WHERE path = ?", arguments: [path])
        }
    }

    /// Batch delete files by path — much faster than N individual deletes.
    /// Also removes children of deleted directories to handle rm -rf correctly.
    func deleteFiles(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try database.dbPool.write { db in
            for chunk in stride(from: 0, to: paths.count, by: 500) {
                let end = min(chunk + 500, paths.count)
                let batch = Array(paths[chunk..<end])
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM files WHERE path IN (\(placeholders))",
                    arguments: StatementArguments(batch)
                )
            }
        }
    }

    // MARK: - Stale Files

    nonisolated func staleFiles(accessedBefore cutoff: Double, minSize: Int64 = 1_048_576) throws -> [FileNode] {
        try database.dbPool.read { db in
            try FileNode
                .filter(Column("is_directory") == false)
                .filter(Column("accessed_at") != nil)
                .filter(Column("accessed_at") < cutoff)
                .filter(Column("size") >= minSize)
                .order(Column("accessed_at").asc)
                .limit(500)
                .fetchAll(db)
        }
    }

    // MARK: - Cache Patterns

    func cachePatternCount() throws -> Int {
        try database.dbPool.read { db in
            try CachePattern.fetchCount(db)
        }
    }

    func allCachePatterns() throws -> [CachePattern] {
        try database.dbPool.read { db in
            try CachePattern.fetchAll(db)
        }
    }

    func insertCachePatterns(_ patterns: [(String, String, String, String)]) throws {
        try database.dbPool.write { db in
            for (pattern, category, safety, description) in patterns {
                var cp = CachePattern(pattern: pattern, category: category, safety: safety, description: description)
                try cp.insert(db)
            }
        }
    }

    func matchingPathSummary(likePattern: String, previewLimit: Int = 20) throws -> ([String], Int, Int64) {
        try database.dbPool.read { db in
            let summary = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS count, COALESCE(SUM(size), 0) AS total_size
                FROM files
                WHERE path LIKE ? AND is_directory = 0
                """, arguments: [likePattern])

            let count: Int = summary?["count"] ?? 0
            let totalSize: Int64 = summary?["total_size"] ?? 0

            let previewRows = try Row.fetchAll(db, sql: """
                SELECT path
                FROM files
                WHERE path LIKE ? AND is_directory = 0
                ORDER BY size DESC
                LIMIT ?
                """, arguments: [likePattern, previewLimit])

            let paths = previewRows.compactMap { $0["path"] as String? }
            return (paths, count, totalSize)
        }
    }

    /// Fast directory-name-based cache detection. Uses idx_files_session_dir_name index
    /// instead of full table LIKE scans. Returns matching directories with pre-computed sizes.
    nonisolated func detectCacheDirectories(name: String) throws -> [(path: String, size: Int64)] {
        try database.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT path, size FROM files
                WHERE name = ? AND is_directory = 1 AND size > 0
                ORDER BY size DESC
                """, arguments: [name])
            return rows.map { (path: $0["path"] as String, size: $0["size"] as Int64) }
        }
    }

    /// Fast prefix-path cache detection for patterns like ~/Library/Caches/*.
    /// Uses idx_files_parent_covering index.
    nonisolated func detectCacheChildren(parentPath: String) throws -> [(path: String, name: String, size: Int64)] {
        try database.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT path, name, size FROM files
                WHERE parent_path = ? AND is_directory = 1 AND size > 0
                ORDER BY size DESC
                """, arguments: [parentPath])
            return rows.map { (path: $0["path"] as String, name: $0["name"] as String, size: $0["size"] as Int64) }
        }
    }

    /// Fast exact-path cache detection.
    nonisolated func detectCacheExact(path: String) throws -> (path: String, size: Int64)? {
        try database.dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT path, size FROM files WHERE path = ?
                """, arguments: [path]) else { return nil }
            return (path: row["path"] as String, size: row["size"] as Int64)
        }
    }

    func allMatchingPaths(likePattern: String) throws -> [String] {
        try database.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT path
                FROM files
                WHERE path LIKE ? AND is_directory = 0
                """, arguments: [likePattern])
            return rows.compactMap { $0["path"] as String? }
        }
    }

    // MARK: - Incremental Sync Helpers

    /// Lightweight map of all file paths → modifiedAt for incremental comparison.
    /// Uses Row cursor to avoid loading full FileNode objects into memory.
    nonisolated func existingFileModifiedTimes() throws -> [String: Double?] {
        try database.dbPool.read { db in
            var result: [String: Double?] = [:]
            let cursor = try Row.fetchCursor(db, sql: "SELECT path, modified_at FROM files")
            while let row = try cursor.next() {
                let path: String = row["path"]
                let modifiedAt: Double? = row["modified_at"]
                result[path] = modifiedAt
            }
            return result
        }
    }

    /// Update session's completedAt timestamp without modifying other fields.
    /// Used after incremental sync to mark the session as fresh (prevents re-triggering stale check).
    func updateSessionCompletedAt(id: Int64) throws {
        try database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE scan_sessions SET completed_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, id]
            )
        }
    }

    /// Recompute session stats (file_count, total_size, indexed_size) from the files table
    /// and update completed_at. Called after incremental sync and file deletion mutations
    /// so that pre-computed stats remain accurate for cold-launch reads.
    func updateSessionStats(id: Int64) throws {
        try database.dbPool.write { db in
            let stats = try Row.fetchOne(db, sql: """
                SELECT
                  COUNT(CASE WHEN is_directory = 0 THEN 1 END) as count,
                  COALESCE(SUM(size), 0) as total,
                  COALESCE(SUM(CASE WHEN is_directory = 0 THEN size ELSE 0 END), 0) as indexed
                FROM files WHERE scan_session_id = ?
                """, arguments: [id])
            try db.execute(sql: """
                UPDATE scan_sessions
                SET file_count = ?, total_size = ?, indexed_size = ?, completed_at = ?
                WHERE id = ?
                """, arguments: [
                    stats?["count"] ?? 0,
                    stats?["total"] ?? 0,
                    stats?["indexed"] ?? 0,
                    Date().timeIntervalSince1970,
                    id
                ])
        }
    }

    /// Per-directory children lookup for quickSync — returns [path: modifiedAt] for direct children.
    /// Nonisolated for concurrent read access (same pattern as rootNodeConcurrent).
    nonisolated func existingChildrenModifiedTimes(parentPath: String) throws -> [String: Double?] {
        try database.dbPool.read { db in
            var result: [String: Double?] = [:]
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT path, modified_at FROM files WHERE parent_path = ?
                """, arguments: [parentPath])
            while let row = try cursor.next() {
                let path: String = row["path"]
                let modifiedAt: Double? = row["modified_at"]
                result[path] = modifiedAt
            }
            return result
        }
    }

    /// Returns paths of subdirectories under a parent — used by quickSync's unchanged-directory
    /// path to recurse via DB instead of filesystem call.
    nonisolated func existingSubdirectoryPaths(parentPath: String) throws -> [String] {
        try database.dbPool.read { db in
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT path FROM files WHERE parent_path = ? AND is_directory = 1
                """, arguments: [parentPath])
            var paths: [String] = []
            while let row = try cursor.next() {
                paths.append(row["path"] as String)
            }
            return paths
        }
    }

    /// Recursively delete a directory and all its descendants from the DB.
    /// Uses substr prefix matching instead of LIKE to handle % and _ in filenames safely.
    func deleteFilesRecursive(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try database.dbPool.write { db in
            for path in paths {
                try db.execute(sql: """
                    DELETE FROM files WHERE path = ?1
                    OR (length(path) > length(?1) AND substr(path, 1, length(?1) + 1) = ?1 || '/')
                    """, arguments: [path])
            }
        }
    }

    // MARK: - Concurrent Read Access

    /// Nonisolated read methods that bypass actor serialization for read-only queries.
    /// Safe because Database is Sendable, `database` is a `let` property, and
    /// DatabasePool.read supports concurrent reads with writes.
    /// This prevents visualization reads from blocking behind FSEvents write batches.

    nonisolated func rootNodeConcurrent() throws -> FileNode? {
        try database.dbPool.read { db in
            try FileNode
                .filter(Column("parent_path") == nil)
                .fetchOne(db)
            ?? FileNode
                .filter(Column("parent_path") == "")
                .filter(Column("is_directory") == true)
                .fetchOne(db)
            ?? FileNode
                .filter(Column("parent_path") == "/..")
                .filter(Column("is_directory") == true)
                .fetchOne(db)
        }
    }

    nonisolated func childrenWithSizesConcurrent(ofPath path: String) throws -> [FileNode] {
        try database.dbPool.read { db in
            try FileNode
                .filter(Column("parent_path") == path)
                .filter(Column("size") > 0)
                .order(Column("size").desc)
                .fetchAll(db)
        }
    }

    nonisolated func directoryChildrenConcurrent(ofPath path: String) throws -> [FileNode] {
        try database.dbPool.read { db in
            try FileNode
                .filter(Column("parent_path") == path)
                .filter(Column("is_directory") == true)
                .filter(Column("size") > 0)
                .order(Column("size").desc)
                .fetchAll(db)
        }
    }

    // MARK: - FSEvents

    func updateEventId(sessionId: Int64, eventId: Int64) throws {
        try database.dbPool.write { db in
            try db.execute(sql: "UPDATE scan_sessions SET last_fsevents_id = ? WHERE id = ?", arguments: [eventId, sessionId])
        }
    }

    /// Synchronous, nonisolated event ID save for use in app termination handlers
    /// where async/await is not available. Safe because Database is Sendable and
    /// DatabasePool is thread-safe.
    nonisolated func updateEventIdSync(sessionId: Int64, eventId: Int64) {
        try? database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE scan_sessions SET last_fsevents_id = ? WHERE id = ?",
                arguments: [eventId, sessionId]
            )
        }
    }

    /// Recalculate directory sizes from the given path up to the root.
    /// Called after FSEvents incremental file changes to keep parent sizes accurate.
    func updateAncestorSizes(forPaths paths: Set<String>) throws {
        // Collect unique ancestor directories from all changed paths
        var ancestors = Set<String>()
        for path in paths {
            var current = (path as NSString).deletingLastPathComponent
            while !current.isEmpty && current != "/" {
                if !ancestors.insert(current).inserted { break } // already have this and all its parents
                let parent = (current as NSString).deletingLastPathComponent
                if parent == current { break }
                current = parent
            }
        }

        guard !ancestors.isEmpty else { return }

        // Sort deepest first so children are updated before parents
        let sorted = ancestors.sorted { $0.components(separatedBy: "/").count > $1.components(separatedBy: "/").count }

        try database.dbPool.write { db in
            for dirPath in sorted {
                try db.execute(sql: """
                    UPDATE files SET size = (
                        SELECT COALESCE(SUM(f2.size), 0) FROM files f2 WHERE f2.parent_path = ?
                    ) WHERE path = ? AND is_directory = 1
                    """, arguments: [dirPath, dirPath])
            }
        }
    }

    /// Recomputes the current root node from its direct children.
    /// Needed when the scan root itself is "/" because updateAncestorSizes stops before it.
    func refreshRootDirectorySize() throws {
        try database.dbPool.write { db in
            guard var root = try FileNode
                .filter(Column("parent_path") == nil)
                .fetchOne(db)
                ?? FileNode
                .filter(Column("parent_path") == "")
                .filter(Column("is_directory") == true)
                .fetchOne(db)
                ?? FileNode
                .filter(Column("parent_path") == "/..")
                .filter(Column("is_directory") == true)
                .fetchOne(db)
            else { return }

            let total = try Int64.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(size), 0)
                    FROM files
                    WHERE parent_path = ?
                    """,
                arguments: [root.path]
            ) ?? 0

            guard root.size != total else { return }
            root.size = total
            try root.insert(db, onConflict: .replace)
        }
    }

    // MARK: - Path Existence Sweep

    struct PruneCandidate {
        let id: Int64
        let path: String
        let size: Int64
        let isDirectory: Bool
    }

    /// Read-only chunked iteration over files in a session, ordered by id, for the
    /// background sweep. Nonisolated so the sweep doesn't serialize with FSEvents
    /// writes (gotcha #26).
    nonisolated func pruneCandidates(
        sessionId: Int64,
        afterId: Int64,
        limit: Int = 5000
    ) throws -> [PruneCandidate] {
        try database.dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, path, size, is_directory
                FROM files
                WHERE scan_session_id = ? AND id > ?
                ORDER BY id
                LIMIT ?
                """, arguments: [sessionId, afterId, limit])
                .map { row in
                    PruneCandidate(
                        id: row["id"],
                        path: row["path"],
                        size: row["size"],
                        isDirectory: row["is_directory"]
                    )
                }
        }
    }

    /// Apply one batch of sweep results: delete missing rows, update divergent file
    /// sizes, return the parent paths that need ancestor recomputation. Caller is
    /// responsible for invoking `updateAncestorSizes(forPaths:)` once all batches
    /// are processed (lets a single recompute pass cover the whole sweep).
    func applyPruneSweepBatch(
        missingPaths: [String],
        sizeUpdates: [(path: String, size: Int64)]
    ) throws -> Set<String> {
        var dirtyParents = Set<String>()
        for path in missingPaths {
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty { dirtyParents.insert(parent) }
        }
        for (path, _) in sizeUpdates {
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty { dirtyParents.insert(parent) }
        }

        if !missingPaths.isEmpty {
            try deleteFiles(paths: missingPaths)
        }
        if !sizeUpdates.isEmpty {
            try database.dbPool.write { db in
                for (path, size) in sizeUpdates {
                    try db.execute(
                        sql: "UPDATE files SET size = ? WHERE path = ?",
                        arguments: [size, path]
                    )
                }
            }
        }
        return dirtyParents
    }

    // MARK: - Export

    func allFiles(forSession sessionId: Int64) throws -> [FileNode] {
        try database.dbPool.read { db in
            try FileNode.filter(Column("scan_session_id") == sessionId)
                .order(Column("path"))
                .fetchAll(db)
        }
    }

    nonisolated func exportPage(forSession sessionId: Int64, afterID lastID: Int64, limit: Int) throws -> [FileNode] {
        try database.dbPool.read { db in
            try FileNode.filter(Column("scan_session_id") == sessionId)
                .filter(Column("id") > lastID)
                .order(Column("id"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Growth Analysis

    func recentlyGrowingFolders(createdAfter cutoff: Double, limit: Int = 50, excludePrefix: String? = nil) throws -> [FolderGrowth] {
        try recentlyGrowingFoldersConcurrent(createdAfter: cutoff, limit: limit, excludePrefix: excludePrefix)
    }

    func cachedGrowthFolders(sessionId: Int64, period: GrowthPeriod) throws -> [FolderGrowth]? {
        try database.dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT payload
                    FROM growth_cache
                    WHERE scan_session_id = ? AND period = ? AND cache_version = ?
                    LIMIT 1
                    """,
                arguments: [sessionId, period.rawValue, growthCacheVersion]
            ) else { return nil }

            let payload: String = row["payload"]
            guard let data = payload.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([FolderGrowth].self, from: data)
        }
    }

    /// Nonisolated DB cache read — bypasses actor for fast synchronous access in switchGrowthPeriod().
    nonisolated func cachedGrowthFoldersConcurrent(sessionId: Int64, period: GrowthPeriod) -> [FolderGrowth]? {
        try? database.dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT payload
                    FROM growth_cache
                    WHERE scan_session_id = ? AND period = ? AND cache_version = ?
                    LIMIT 1
                    """,
                arguments: [sessionId, period.rawValue, growthCacheVersion]
            ) else { return nil }

            let payload: String = row["payload"]
            guard let data = payload.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([FolderGrowth].self, from: data)
        }
    }

    func upsertGrowthCache(sessionId: Int64, period: GrowthPeriod, folders: [FolderGrowth]) throws {
        let payloadData = try JSONEncoder().encode(folders)
        guard let payload = String(data: payloadData, encoding: .utf8) else { return }

        try database.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO growth_cache (scan_session_id, period, payload, generated_at, cache_version)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(scan_session_id, period) DO UPDATE SET
                    payload = excluded.payload,
                    generated_at = excluded.generated_at,
                    cache_version = excluded.cache_version
                """, arguments: [
                    sessionId,
                    period.rawValue,
                    payload,
                    Date().timeIntervalSince1970,
                    growthCacheVersion
                ])
        }
    }

    nonisolated func recentlyGrowingFoldersConcurrent(createdAfter cutoff: Double, limit: Int = 50, excludePrefix: String? = nil) throws -> [FolderGrowth] {
        try database.dbPool.read { db in
            // Step 1: Aggregate top folders by recent growth (covered by idx_files_growth partial index)
            let likePattern = excludePrefix.map { $0 + "%" }
            let excludeClause = likePattern != nil ? "\n                  AND parent_path NOT LIKE ?" : ""
            var aggArgs: [DatabaseValueConvertible] = [cutoff]
            if let pat = likePattern { aggArgs.append(pat) }
            aggArgs.append(limit)

            let growthRows = try Row.fetchAll(db, sql: """
                SELECT parent_path, SUM(size) AS recent_size, COUNT(*) AS recent_count
                FROM files INDEXED BY idx_files_growth
                WHERE is_directory = 0
                  AND size > 0
                  AND created_at IS NOT NULL
                  AND created_at >= ?\(excludeClause)
                GROUP BY parent_path
                ORDER BY recent_size DESC
                LIMIT ?
                """, arguments: StatementArguments(aggArgs))

            guard !growthRows.isEmpty else { return [] }

            // Step 2: Batch-fetch directory metadata for the top paths
            let parentPaths: [String] = growthRows.map { $0["parent_path"] }
            let placeholders = parentPaths.map { _ in "?" }.joined(separator: ", ")
            let dirArgs = StatementArguments(parentPaths)

            let dirRows = try Row.fetchAll(db, sql: """
                SELECT path, name, size FROM files
                WHERE is_directory = 1 AND path IN (\(placeholders))
                """, arguments: dirArgs)

            var dirLookup: [String: (name: String, size: Int64)] = [:]
            for row in dirRows {
                let path: String = row["path"]
                dirLookup[path] = (name: row["name"], size: row["size"])
            }

            // Combine: growth aggregate + directory metadata
            return growthRows.map { row in
                let parentPath: String = row["parent_path"]
                let dirInfo = dirLookup[parentPath]
                let folderName = dirInfo?.name ?? URL(fileURLWithPath: parentPath).lastPathComponent
                return FolderGrowth(
                    folderPath: parentPath,
                    folderName: folderName,
                    totalFolderSize: dirInfo?.size ?? 0,
                    recentGrowthSize: row["recent_size"],
                    recentFileCount: row["recent_count"]
                )
            }
        }
    }

    // MARK: - Search

    func searchFiles(query: String, limit: Int = 100) throws -> [FileNode] {
        let pattern = "%\(query)%"
        return try database.dbPool.read { db in
            try FileNode
                .filter(Column("name").like(pattern))
                .order(Column("size").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Smart Cleanup

    func nonDirectoryFileCount(forSession sessionId: Int64) throws -> Int {
        try database.dbPool.read { db in
            try FileNode
                .filter(Column("scan_session_id") == sessionId)
                .filter(Column("is_directory") == false)
                .fetchCount(db)
        }
    }

    func nonDirectoryFiles(forSession sessionId: Int64, limit: Int, offset: Int) throws -> [FileNode] {
        try database.dbPool.read { db in
            try FileNode
                .filter(Column("scan_session_id") == sessionId)
                .filter(Column("is_directory") == false)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// Cursor-based pagination: fetch files with id > afterId, ordered by id.
    /// O(1) per page regardless of position (vs OFFSET which is O(page_number)).
    /// Nonisolated to avoid actor contention with FSEvents writes during analysis.
    nonisolated func nonDirectoryFilesAfter(id afterId: Int64, forSession sessionId: Int64, limit: Int) throws -> [FileNode] {
        try database.dbPool.read { db in
            try FileNode
                .filter(Column("scan_session_id") == sessionId)
                .filter(Column("is_directory") == false)
                .filter(Column("id") > afterId)
                .order(Column("id"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Run a single cleanup rule as a SQL query, returning recommendations.
    /// Nonisolated for performance — read-only query.
    nonisolated func queryCleanupRule(
        sessionId: Int64,
        rule: String,
        category: FileCategoryType,
        confidence: DeletionConfidence,
        explanation: String,
        signals: [CleanupSignal],
        condition: String,
        isDirectoryRule: Bool
    ) throws -> [CleanupRecommendation] {
        try database.dbPool.read { db in
            let sql = """
                SELECT path, name, size, accessed_at, modified_at
                FROM files
                WHERE scan_session_id = ? AND \(condition)
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [sessionId])
            let fm = FileManager.default
            return rows.compactMap { row in
                let path: String = row["path"]
                guard !IndexedPathRules.isPseudoFilesystemPath(path) else { return nil }
                guard fm.fileExists(atPath: path) else { return nil }
                let name: String = row["name"]
                let dbSize: Int64 = row["size"]
                let accessedAt: Double? = row["accessed_at"]
                let modifiedAt: Double? = row["modified_at"]

                // For directories, compute actual size from filesystem instead of
                // trusting the DB — stale records from missed FSEvents can inflate
                // directory sizes by orders of magnitude.
                let size: Int64
                if isDirectoryRule {
                    size = Self.actualDirectorySize(at: path, fm: fm)
                } else {
                    size = dbSize
                }

                return CleanupRecommendation(
                    id: path,
                    filePath: path,
                    fileName: name,
                    fileSize: size,
                    category: category,
                    confidence: confidence,
                    explanation: "\(explanation) (\(rule))",
                    signals: signals,
                    llmEnhanced: false,
                    scanSessionId: sessionId,
                    accessedAt: accessedAt,
                    modifiedAt: modifiedAt
                )
            }
        }
    }

    /// Walk a directory and sum actual on-disk allocated sizes.
    private static func actualDirectorySize(at path: String, fm: FileManager) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    nonisolated func insertRecommendations(_ records: [CleanupRecommendationRecord]) throws {
        try database.dbPool.write { db in
            for var record in records {
                try record.insert(db)
            }
        }
    }

    func recommendations(forSession sessionId: Int64) throws -> [CleanupRecommendationRecord] {
        try database.dbPool.read { db in
            try CleanupRecommendationRecord
                .filter(Column("scan_session_id") == sessionId)
                .order(Column("confidence").asc, Column("file_size").desc)
                .fetchAll(db)
        }
    }

    func recommendations(forSession sessionId: Int64, confidence: String) throws -> [CleanupRecommendationRecord] {
        try database.dbPool.read { db in
            try CleanupRecommendationRecord
                .filter(Column("scan_session_id") == sessionId)
                .filter(Column("confidence") == confidence)
                .order(Column("file_size").desc)
                .fetchAll(db)
        }
    }

    nonisolated func deleteRecommendations(forSession sessionId: Int64) throws {
        try database.dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM cleanup_recommendations WHERE scan_session_id = ?",
                arguments: [sessionId]
            )
        }
    }

    func deleteRecommendations(forFilePaths paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try database.dbPool.write { db in
            for chunk in stride(from: 0, to: paths.count, by: 500) {
                let end = min(chunk + 500, paths.count)
                let batch = Array(paths[chunk..<end])
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM cleanup_recommendations WHERE file_path IN (\(placeholders))",
                    arguments: StatementArguments(batch)
                )
            }
        }
    }

    nonisolated func recommendationSummary(forSession sessionId: Int64) throws -> CleanupSummary {
        try database.dbPool.read { db in
            // Total by confidence
            let confidenceRows = try Row.fetchAll(db, sql: """
                SELECT confidence, COALESCE(SUM(file_size), 0) as total_size, COUNT(*) as count
                FROM cleanup_recommendations WHERE scan_session_id = ?
                GROUP BY confidence
                """, arguments: [sessionId])

            var totalReclaimable: Int64 = 0
            var safeReclaimable: Int64 = 0
            var cautionReclaimable: Int64 = 0
            var riskyReclaimable: Int64 = 0
            var totalCount = 0

            for row in confidenceRows {
                let conf: String = row["confidence"]
                let size: Int64 = row["total_size"]
                let count: Int = row["count"]
                totalReclaimable += size
                totalCount += count
                switch conf {
                case "safe": safeReclaimable = size
                case "caution": cautionReclaimable = size
                case "risky": riskyReclaimable = size
                default: break
                }
            }

            // Category breakdown
            let categoryRows = try Row.fetchAll(db, sql: """
                SELECT category, COALESCE(SUM(file_size), 0) as total_size, COUNT(*) as count
                FROM cleanup_recommendations WHERE scan_session_id = ?
                GROUP BY category ORDER BY total_size DESC
                """, arguments: [sessionId])

            let categoryBreakdown: [(FileCategoryType, Int64, Int)] = categoryRows.compactMap { row in
                let cat: String = row["category"]
                let size: Int64 = row["total_size"]
                let count: Int = row["count"]
                guard let categoryType = FileCategoryType(rawValue: cat) else { return nil }
                return (categoryType, size, count)
            }

            return CleanupSummary(
                totalReclaimable: totalReclaimable,
                safeReclaimable: safeReclaimable,
                cautionReclaimable: cautionReclaimable,
                riskyReclaimable: riskyReclaimable,
                categoryBreakdown: categoryBreakdown,
                totalCount: totalCount
            )
        }
    }
}
