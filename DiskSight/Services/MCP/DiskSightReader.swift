import Foundation

// DiskSightReader — the public, read-only facade over the app's verified
// FileRepository read methods. It lives in DiskSightCore so it can call the
// repository's internal `*Concurrent` read methods directly (same module),
// while exposing only small Codable DTOs across the module boundary to the
// standalone MCP server. The app does NOT compile this file (it is not in the
// app's Xcode target) — it is reader-only.
//
// The reader opens the shared SQLite database READ-ONLY (query_only = ON, no
// migrations, no checkpoint) so it never mutates state the running app owns.

// MARK: - Errors

public enum DiskSightReaderError: Error, CustomStringConvertible {
    /// No database file exists yet — the user has never run a scan.
    case noIndex
    /// A database exists but contains no completed scan session.
    case noScan

    public var description: String {
        switch self {
        case .noIndex:
            return "No DiskSight index found. Open DiskSight and run a scan first."
        case .noScan:
            return "DiskSight has no completed scan yet. Run a scan in DiskSight first."
        }
    }
}

// MARK: - DTOs

public struct FileInfo: Codable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let sizeBytes: Int64
    public let sizeHuman: String
    public let modifiedAt: Date?
    public let accessedAt: Date?
    public let fileType: String?
}

public struct PathSizeInfo: Codable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let sizeBytes: Int64
    public let sizeHuman: String
}

public struct FileTypeShare: Codable, Sendable {
    public let fileType: String
    public let sizeBytes: Int64
    public let sizeHuman: String
}

public struct DuplicateGroupInfo: Codable, Sendable {
    public let contentHash: String
    public let fileSizeBytes: Int64
    public let fileSizeHuman: String
    public let copies: Int
    public let reclaimableBytes: Int64
    public let reclaimableHuman: String
    public let paths: [String]
}

public struct BloatReportInfo: Codable, Sendable {
    public let fileTypes: [FileTypeShare]
    public let largestFiles: [PathSizeInfo]
    public let duplicateGroups: [DuplicateGroupInfo]
}

public struct CleanupCandidateInfo: Codable, Sendable {
    public let path: String
    public let name: String
    public let sizeBytes: Int64
    public let sizeHuman: String
    public let category: String
    public let confidence: String
    public let explanation: String
    public let signals: [String]
}

public struct CleanupReportInfo: Codable, Sendable {
    public let totalReclaimableBytes: Int64
    public let totalReclaimableHuman: String
    public let safeReclaimableBytes: Int64
    public let cautionReclaimableBytes: Int64
    public let riskyReclaimableBytes: Int64
    public let totalCount: Int
    public let candidates: [CleanupCandidateInfo]
}

public struct CacheHotspotInfo: Codable, Sendable {
    public let pattern: String
    public let category: String
    public let safety: String
    public let matchCount: Int
    public let sizeBytes: Int64
    public let sizeHuman: String
    public let previewPaths: [String]
}

public struct GrowthHotspotInfo: Codable, Sendable {
    public let folderPath: String
    public let folderName: String
    public let totalFolderBytes: Int64
    public let totalFolderHuman: String
    public let recentGrowthBytes: Int64
    public let recentGrowthHuman: String
    public let recentFileCount: Int
}

public struct GrowthReportInfo: Codable, Sendable {
    /// False when growth has not been computed for this session/period yet.
    /// The reader never recomputes growth (it can be O(millions of rows)); the
    /// app computes and caches it. When false, `folders` is empty.
    public let computed: Bool
    public let period: String
    public let folders: [GrowthHotspotInfo]
    public let note: String?
}

public struct ScanStatusInfo: Codable, Sendable {
    public let hasIndex: Bool
    public let rootPath: String?
    public let fileCount: Int?
    public let totalSizeBytes: Int64?
    public let totalSizeHuman: String?
    public let indexedSizeBytes: Int64?
    public let startedAt: Date?
    public let completedAt: Date?
    public let ageSeconds: Double?
    public let scanInProgress: Bool
    /// Directories the last scan could not read. > 0 means the index is
    /// incomplete even though the scan "completed" (usually missing Full Disk
    /// Access). nil on databases predating skipped-dir tracking.
    public let skippedDirectories: Int?
    public let databaseFileBytes: Int64
    public let databaseFileHuman: String
}

// MARK: - Reader

public struct DiskSightReader: Sendable {
    private let database: Database
    private let repository: FileRepository

    /// Default shared database location (app is not sandboxed, so this is the
    /// real Application Support path the app writes to).
    public static var defaultDatabaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("DiskSight", isDirectory: true)
            .appendingPathComponent("disksight.sqlite")
    }

    /// Opens the database read-only. Throws `DiskSightReaderError.noIndex` if no
    /// database exists yet.
    public init(databaseURL: URL = DiskSightReader.defaultDatabaseURL) throws {
        do {
            self.database = try Database(readOnlyURL: databaseURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            throw DiskSightReaderError.noIndex
        }
        self.repository = FileRepository(database: database)
    }

    // MARK: Limits

    /// Clamp a requested limit into a sane, capped range.
    private func cap(_ requested: Int?, defaultValue: Int, maximum: Int = 100) -> Int {
        let value = requested ?? defaultValue
        return max(1, min(value, maximum))
    }

    private func humanSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func date(_ timestamp: Double?) -> Date? {
        timestamp.map { Date(timeIntervalSince1970: $0) }
    }

    private func fileInfo(_ node: FileNode) -> FileInfo {
        FileInfo(
            path: node.path,
            name: node.name,
            isDirectory: node.isDirectory,
            sizeBytes: node.size,
            sizeHuman: humanSize(node.size),
            modifiedAt: date(node.modifiedAt),
            accessedAt: date(node.accessedAt),
            fileType: node.fileType
        )
    }

    private func pathSizeInfo(_ node: FileNode) -> PathSizeInfo {
        PathSizeInfo(
            path: node.path,
            name: node.name,
            isDirectory: node.isDirectory,
            sizeBytes: node.size,
            sizeHuman: humanSize(node.size)
        )
    }

    /// The latest completed scan session, or throw `.noScan`.
    private func requireCompletedSession() throws -> ScanSession {
        guard let session = try repository.latestCompletedScanSession() else {
            throw DiskSightReaderError.noScan
        }
        return session
    }

    // MARK: - Tools

    public func scanStatus() throws -> ScanStatusInfo {
        let latest = try repository.latestScanSession()
        let completed = try repository.latestCompletedScanSession()
        let dbBytes = repository.databaseFileSizeBytes()

        guard let session = completed ?? latest else {
            return ScanStatusInfo(
                hasIndex: true, rootPath: nil, fileCount: nil,
                totalSizeBytes: nil, totalSizeHuman: nil, indexedSizeBytes: nil,
                startedAt: nil, completedAt: nil, ageSeconds: nil,
                scanInProgress: false, skippedDirectories: nil,
                databaseFileBytes: dbBytes, databaseFileHuman: humanSize(dbBytes)
            )
        }

        let scanInProgress: Bool = {
            guard let latest else { return false }
            return latest.completedAt == nil
        }()

        let total = session.totalSize
        let age = session.completedAt.map { Date().timeIntervalSince1970 - $0 }

        return ScanStatusInfo(
            hasIndex: true,
            rootPath: session.rootPath,
            fileCount: session.fileCount,
            totalSizeBytes: total,
            totalSizeHuman: total.map { humanSize($0) },
            indexedSizeBytes: session.indexedSize,
            startedAt: date(session.startedAt),
            completedAt: date(session.completedAt),
            ageSeconds: age,
            scanInProgress: scanInProgress,
            skippedDirectories: session.skippedDirectories,
            databaseFileBytes: dbBytes,
            databaseFileHuman: humanSize(dbBytes)
        )
    }

    public func bloatReport(largestLimit: Int? = nil, duplicateLimit: Int? = nil) throws -> BloatReportInfo {
        let report = try repository.bloatReport(
            largestLimit: cap(largestLimit, defaultValue: 20),
            duplicateLimit: cap(duplicateLimit, defaultValue: 25)
        )

        let fileTypes = report.fileTypes.map {
            FileTypeShare(fileType: $0.0, sizeBytes: $0.1, sizeHuman: humanSize($0.1))
        }
        let largest = report.largest.map { pathSizeInfo($0) }
        let dupes = report.duplicates.map { group -> DuplicateGroupInfo in
            DuplicateGroupInfo(
                contentHash: group.id,
                fileSizeBytes: group.fileSize,
                fileSizeHuman: humanSize(group.fileSize),
                copies: group.files.count,
                reclaimableBytes: group.reclaimableSize,
                reclaimableHuman: humanSize(group.reclaimableSize),
                paths: group.files.map(\.path)
            )
        }
        return BloatReportInfo(fileTypes: fileTypes, largestFiles: largest, duplicateGroups: dupes)
    }

    /// Largest immediate children of `path` (the scan root if `path` is nil).
    public func topPaths(path: String? = nil, limit: Int? = nil) throws -> [PathSizeInfo] {
        let capped = cap(limit, defaultValue: 20)
        let targetPath: String?
        if let path { targetPath = path }
        else { targetPath = try repository.rootNodeConcurrent()?.path }

        guard let targetPath else { return [] }
        return try repository
            .childrenWithSizesConcurrent(ofPath: targetPath, limit: capped)
            .map { pathSizeInfo($0) }
    }

    public func cleanupCandidates(confidence: String? = nil, limit: Int? = nil) throws -> CleanupReportInfo {
        let session = try requireCompletedSession()
        guard let sessionId = session.id else { throw DiskSightReaderError.noScan }
        let capped = cap(limit, defaultValue: 30)

        let summary = try repository.recommendationSummary(forSession: sessionId)
        let records: [CleanupRecommendationRecord]
        if let confidence, !confidence.isEmpty {
            records = try repository.recommendationsConcurrent(forSession: sessionId, confidence: confidence)
        } else {
            records = try repository.recommendationsConcurrent(forSession: sessionId)
        }

        let candidates = records.prefix(capped).map { rec -> CleanupCandidateInfo in
            let model = rec.toRecommendation()
            return CleanupCandidateInfo(
                path: model.filePath,
                name: model.fileName,
                sizeBytes: model.fileSize,
                sizeHuman: humanSize(model.fileSize),
                category: model.category.rawValue,
                confidence: model.confidence.rawValue,
                explanation: model.explanation,
                signals: model.signals.map(\.rawValue)
            )
        }

        return CleanupReportInfo(
            totalReclaimableBytes: summary.totalReclaimable,
            totalReclaimableHuman: humanSize(summary.totalReclaimable),
            safeReclaimableBytes: summary.safeReclaimable,
            cautionReclaimableBytes: summary.cautionReclaimable,
            riskyReclaimableBytes: summary.riskyReclaimable,
            totalCount: summary.totalCount,
            candidates: Array(candidates)
        )
    }

    public func cacheHotspots(limit: Int? = nil) async throws -> [CacheHotspotInfo] {
        let capped = cap(limit, defaultValue: 20)
        let detector = CacheDetector(repository: repository)
        // Read-only reader: must not seed/write the cache_patterns table.
        let caches = try await detector.detectCaches(seedIfEmpty: false)
        return caches.prefix(capped).map { cache in
            CacheHotspotInfo(
                pattern: cache.pattern.pattern,
                category: cache.pattern.category,
                safety: cache.pattern.safetyLevel.label,
                matchCount: cache.matchCount,
                sizeBytes: cache.totalSize,
                sizeHuman: humanSize(cache.totalSize),
                previewPaths: Array(cache.previewPaths.prefix(20))
            )
        }
    }

    /// Growth is CACHE-ONLY: the reader never recomputes it (potentially millions
    /// of rows). If the app has not computed/cached growth for this period, the
    /// result reports `computed = false`.
    public func growthHotspots(period: String? = nil, limit: Int? = nil) throws -> GrowthReportInfo {
        let session = try requireCompletedSession()
        guard let sessionId = session.id else { throw DiskSightReaderError.noScan }
        let capped = cap(limit, defaultValue: 20)

        let resolvedPeriod = GrowthPeriod(rawValue: period ?? "") ?? .thirtyDays
        guard let cached = repository.cachedGrowthFoldersConcurrent(sessionId: sessionId, period: resolvedPeriod) else {
            return GrowthReportInfo(
                computed: false,
                period: resolvedPeriod.rawValue,
                folders: [],
                note: "Growth not computed for this session/period yet. Open the Recent Growth view in DiskSight for the \(resolvedPeriod.rawValue) period to compute it."
            )
        }

        let folders = cached.prefix(capped).map { folder in
            GrowthHotspotInfo(
                folderPath: folder.folderPath,
                folderName: folder.folderName,
                totalFolderBytes: folder.totalFolderSize,
                totalFolderHuman: humanSize(folder.totalFolderSize),
                recentGrowthBytes: folder.recentGrowthSize,
                recentGrowthHuman: humanSize(folder.recentGrowthSize),
                recentFileCount: folder.recentFileCount
            )
        }
        return GrowthReportInfo(computed: true, period: resolvedPeriod.rawValue, folders: Array(folders), note: nil)
    }

    public func staleFiles(threshold: String? = nil, minSizeBytes: Int64? = nil, limit: Int? = nil) throws -> [FileInfo] {
        let capped = cap(limit, defaultValue: 50)
        let resolved = StaleThreshold(rawValue: threshold ?? "") ?? .oneYear
        let cutoff = resolved.cutoffDate.timeIntervalSince1970
        let minSize = minSizeBytes ?? 1_048_576
        return try repository
            .staleFiles(accessedBefore: cutoff, minSize: minSize)
            .prefix(capped)
            .map { fileInfo($0) }
    }

    public func searchFiles(query: String, limit: Int? = nil) throws -> [FileInfo] {
        let capped = cap(limit, defaultValue: 50)
        return try repository
            .searchFilesConcurrent(query: query, limit: capped)
            .map { fileInfo($0) }
    }
}
