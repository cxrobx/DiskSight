import XCTest
import GRDB
@testable import DiskSight

final class ManagedStorageExclusionTests: XCTestCase {
    func testFullScanSkipsManagedStorageDirectory() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let dataDirectory = tempDirectory.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let normalFileURL = dataDirectory.appendingPathComponent("keep.txt")
        try "hello".write(to: normalFileURL, atomically: true, encoding: .utf8)

        let databaseURL = tempDirectory
            .appendingPathComponent("Library/Application Support/DiskSight", isDirectory: true)
            .appendingPathComponent("disksight.sqlite")
        let database = try Database(databaseURL: databaseURL)
        let repository = FileRepository(database: database)

        let session = try await repository.createScanSession(rootPath: tempDirectory.path)
        let sessionId = try XCTUnwrap(session.id)

        let scanner = FileScanner(repository: repository)
        var lastProgress: ScanProgress?
        for await progress in scanner.scan(rootURL: tempDirectory, sessionId: sessionId) {
            lastProgress = progress
        }

        XCTAssertTrue(lastProgress?.completed ?? false)

        let storagePath = database.storageDirectoryURL.path
        let managedCount = try await database.dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM files
                    WHERE path = ? OR path LIKE ?
                    """,
                arguments: [storagePath, storagePath + "/%"]
            ) ?? 0
        }
        XCTAssertEqual(managedCount, 0)

        let scannedFileCount = try await database.dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM files WHERE path LIKE ?",
                arguments: ["%/Data/keep.txt"]
            ) ?? 0
        }
        XCTAssertEqual(scannedFileCount, 1)
    }

    func testPersistentStorageFailureClassificationRecognizesSQLiteIOErrors() {
        let error = DatabaseError(resultCode: .SQLITE_IOERR, message: "disk I/O error")

        XCTAssertTrue(Database.isLikelyPersistentStorageFailure(error))
        XCTAssertFalse(Database.isLikelyPersistentStorageFailure(message: "The folder could not be opened."))
    }
}

final class IndexedPathRulesTests: XCTestCase {
    func testRecognizesDevAndVolPaths() {
        XCTAssertTrue(IndexedPathRules.isPseudoFilesystemPath("/dev"))
        XCTAssertTrue(IndexedPathRules.isPseudoFilesystemPath("/dev/fd/3"))
        XCTAssertTrue(IndexedPathRules.isPseudoFilesystemPath("/.vol"))
        XCTAssertTrue(IndexedPathRules.isPseudoFilesystemPath("/.vol/abc/123"))
    }

    func testIgnoresUnrelatedPaths() {
        XCTAssertFalse(IndexedPathRules.isPseudoFilesystemPath("/devices"))
        XCTAssertFalse(IndexedPathRules.isPseudoFilesystemPath("/Users/foo/dev/project"))
        XCTAssertFalse(IndexedPathRules.isPseudoFilesystemPath("/.volumes"))
    }

    func testRootScanExclusionAppliesOnlyAtRoot() {
        XCTAssertTrue(IndexedPathRules.shouldExcludeDuringRootScan(path: "/dev/fd/3", scanRootPath: "/"))
        XCTAssertFalse(IndexedPathRules.shouldExcludeDuringRootScan(path: "/dev/fd/3", scanRootPath: "/Users/foo"))
    }
}

final class PathSweepRepositoryTests: XCTestCase {
    private func makeRepository() throws -> (FileRepository, URL) {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let databaseURL = tempDirectory
            .appendingPathComponent("Library/Application Support/DiskSight", isDirectory: true)
            .appendingPathComponent("disksight.sqlite")
        let database = try Database(databaseURL: databaseURL)
        return (FileRepository(database: database), tempDirectory)
    }

    func testApplyPruneSweepBatchDeletesMissingAndUpdatesSizes() async throws {
        let (repository, tempDirectory) = try makeRepository()
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDirectory) }

        let session = try await repository.createScanSession(rootPath: tempDirectory.path)
        let sessionId = try XCTUnwrap(session.id)

        let presentURL = tempDirectory.appendingPathComponent("present.txt")
        try "hello".write(to: presentURL, atomically: true, encoding: .utf8)
        let missingPath = tempDirectory.appendingPathComponent("ghost.txt").path
        let parentPath = tempDirectory.path

        try await repository.insertFilesBatch([
            FileNode(path: parentPath, name: tempDirectory.lastPathComponent, parentPath: nil, size: 0, isDirectory: true, scanSessionId: sessionId),
            FileNode(path: presentURL.path, name: "present.txt", parentPath: parentPath, size: 999_999_999, isDirectory: false, scanSessionId: sessionId),
            FileNode(path: missingPath, name: "ghost.txt", parentPath: parentPath, size: 1234, isDirectory: false, scanSessionId: sessionId)
        ])

        let candidates = try repository.pruneCandidates(sessionId: sessionId, afterId: 0)
        XCTAssertEqual(candidates.count, 3)

        let dirty = try await repository.applyPruneSweepBatch(
            missingPaths: [missingPath],
            sizeUpdates: [(path: presentURL.path, size: 5)]
        )
        XCTAssertTrue(dirty.contains(parentPath))

        let remaining = try repository.pruneCandidates(sessionId: sessionId, afterId: 0)
        XCTAssertFalse(remaining.contains { $0.path == missingPath })
        XCTAssertEqual(remaining.first { $0.path == presentURL.path }?.size, 5)
    }
}

final class CleanupRulePseudoFilesystemFilterTests: XCTestCase {
    func testQueryCleanupRuleSkipsDevPaths() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDirectory) }

        let databaseURL = tempDirectory
            .appendingPathComponent("Library/Application Support/DiskSight", isDirectory: true)
            .appendingPathComponent("disksight.sqlite")
        let database = try Database(databaseURL: databaseURL)
        let repository = FileRepository(database: database)

        let session = try await repository.createScanSession(rootPath: "/")
        let sessionId = try XCTUnwrap(session.id)

        try await repository.insertFilesBatch([
            FileNode(path: "/dev/fd/3", name: "3", parentPath: "/dev/fd", size: 33_000_000_000, isDirectory: false, scanSessionId: sessionId)
        ])

        let recommendations = try repository.queryCleanupRule(
            sessionId: sessionId,
            rule: "test_rule",
            category: .unknown,
            confidence: .caution,
            explanation: "synthetic",
            signals: [],
            condition: "1 = 1",
            isDirectoryRule: false
        )

        XCTAssertTrue(
            recommendations.allSatisfy { !$0.filePath.hasPrefix("/dev") },
            "queryCleanupRule must drop /dev/* paths even when the existence check would pass"
        )
    }
}
