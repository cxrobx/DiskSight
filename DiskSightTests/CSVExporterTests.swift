import XCTest
@testable import DiskSight

final class CSVExporterTests: XCTestCase {
    func testStreamExportsMultiplePagesWithoutRepeatingRows() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let databaseURL = tempDirectory.appendingPathComponent("disksight.sqlite")
        let outputURL = tempDirectory.appendingPathComponent("export.csv")
        let database = try Database(databaseURL: databaseURL)
        let repository = FileRepository(database: database)

        let session = try await repository.createScanSession(rootPath: tempDirectory.path)
        let sessionID = try XCTUnwrap(session.id)
        let fileCount = 5_003
        let timestamp = Date().timeIntervalSince1970

        let files = (0..<fileCount).map { index in
            FileNode(
                id: nil,
                path: tempDirectory.appendingPathComponent(String(format: "file-%05d.txt", index)).path,
                name: String(format: "file-%05d.txt", index),
                parentPath: tempDirectory.path,
                size: Int64(index + 1),
                isDirectory: false,
                modifiedAt: timestamp,
                accessedAt: timestamp,
                createdAt: timestamp,
                contentHash: nil,
                partialHash: nil,
                fileType: "txt",
                scanSessionId: sessionID
            )
        }
        try await repository.insertFilesBatch(files)

        try await CSVExporter.stream(from: repository, sessionId: sessionID, to: outputURL)

        let contents = try String(contentsOf: outputURL, encoding: .utf8)
        let lines = contents.split(separator: "\n")

        XCTAssertEqual(lines.first, "path,name,size_bytes,size_formatted,is_directory,file_type,modified_at,accessed_at,created_at")
        XCTAssertEqual(lines.count, fileCount + 1)
        XCTAssertTrue(lines.contains { $0.contains("file-00000.txt") })
        XCTAssertTrue(lines.contains { $0.contains("file-05002.txt") })
    }

    func testCompactionShrinksDatabaseAfterDeletes() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let databaseURL = tempDirectory.appendingPathComponent("disksight.sqlite")
        let database = try Database(databaseURL: databaseURL)
        let repository = FileRepository(database: database)

        let session = try await repository.createScanSession(rootPath: tempDirectory.path)
        let sessionID = try XCTUnwrap(session.id)
        let timestamp = Date().timeIntervalSince1970
        let longHash = String(repeating: "abcdef0123456789", count: 16)

        let files = (0..<8_000).map { index in
            FileNode(
                id: nil,
                path: tempDirectory.appendingPathComponent("folder-\(index)/file-\(index)-\(longHash).txt").path,
                name: "file-\(index).txt",
                parentPath: tempDirectory.path,
                size: Int64(index + 1),
                isDirectory: false,
                modifiedAt: timestamp,
                accessedAt: timestamp,
                createdAt: timestamp,
                contentHash: longHash,
                partialHash: longHash,
                fileType: "txt",
                scanSessionId: sessionID
            )
        }

        try await repository.insertFilesBatch(files)
        try await repository.deleteFiles(paths: files.map(\.path))

        let bytesBeforeCompaction = try totalDatabaseBytes(at: databaseURL)
        let didCompact = try await repository.compactIfNeeded(
            minimumFreeBytes: 4_096,
            minimumFreeRatio: 0,
            minimumWALBytes: 1
        )
        let bytesAfterCompaction = try totalDatabaseBytes(at: databaseURL)

        XCTAssertTrue(didCompact)
        XCTAssertLessThan(bytesAfterCompaction, bytesBeforeCompaction)
    }

    private func totalDatabaseBytes(at databaseURL: URL) throws -> Int64 {
        let fileManager = FileManager.default
        let urls = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]

        return try urls.reduce(into: Int64(0)) { total, url in
            guard fileManager.fileExists(atPath: url.path) else { return }
            let size = try XCTUnwrap(
                try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                "Expected file size for \(url.lastPathComponent)"
            )
            total += Int64(size)
        }
    }
}
