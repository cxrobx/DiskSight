import XCTest
import GRDB
@testable import DiskSight

final class ManagedStorageExclusionTests: XCTestCase {
    func testFullScanSkipsManagedStorageDirectory() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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
        let managedCount = try database.dbPool.read { db in
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

        let scannedFileCount = try database.dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM files WHERE path = ?",
                arguments: [normalFileURL.path]
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
