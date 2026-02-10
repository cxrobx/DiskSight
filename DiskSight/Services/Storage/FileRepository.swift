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
            // Fallback: FSEvents can overwrite root's parent_path to "/.."
            try FileNode
                .filter(Column("parent_path") == nil)
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

    func duplicateGroups() throws -> [DuplicateGroup] {
        try database.dbPool.read { db in
            let hashes = try Row.fetchAll(db, sql: """
                SELECT content_hash, size FROM files
                WHERE is_directory = 0 AND content_hash IS NOT NULL
                GROUP BY content_hash HAVING COUNT(*) > 1
                ORDER BY size * COUNT(*) DESC
                """)

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

    func staleFiles(accessedBefore cutoff: Double, minSize: Int64 = 1_048_576) throws -> [FileNode] {
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

    func matchingPaths(likePattern: String) throws -> ([String], Int64) {
        try database.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT path, size FROM files
                WHERE path LIKE ? AND is_directory = 0
                """, arguments: [likePattern])
            let paths = rows.compactMap { $0["path"] as String? }
            let totalSize = rows.reduce(Int64(0)) { $0 + ($1["size"] as Int64? ?? 0) }
            return (paths, totalSize)
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

    // MARK: - Export

    func allFiles(forSession sessionId: Int64) throws -> [FileNode] {
        try database.dbPool.read { db in
            try FileNode.filter(Column("scan_session_id") == sessionId)
                .order(Column("path"))
                .fetchAll(db)
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

    func nonDirectoryFiles(forSession sessionId: Int64) throws -> [FileNode] {
        try database.dbPool.read { db in
            try FileNode
                .filter(Column("scan_session_id") == sessionId)
                .filter(Column("is_directory") == false)
                .fetchAll(db)
        }
    }

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

    func insertRecommendations(_ records: [CleanupRecommendationRecord]) throws {
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

    func deleteRecommendations(forSession sessionId: Int64) throws {
        try database.dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM cleanup_recommendations WHERE scan_session_id = ?",
                arguments: [sessionId]
            )
        }
    }

    func recommendationSummary(forSession sessionId: Int64) throws -> CleanupSummary {
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
