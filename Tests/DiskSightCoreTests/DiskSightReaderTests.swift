import XCTest
import GRDB
@testable import DiskSightCore

final class DiskSightReaderTests: XCTestCase {

    private func uniqueDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSightReaderTests-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func cleanup(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// Seed a read-write database with a known tree and a completed session.
    private func seed(at url: URL) async throws {
        let db = try Database(databaseURL: url)
        let repo = FileRepository(database: db)
        let session = try await repo.createScanSession(rootPath: "/tmp/root")
        let sid = try XCTUnwrap(session.id)

        let nodes = [
            FileNode(path: "/tmp/root", name: "root", parentPath: nil, size: 0, isDirectory: true, scanSessionId: sid),
            FileNode(path: "/tmp/root/big.bin", name: "big.bin", parentPath: "/tmp/root", size: 5000, isDirectory: false, modifiedAt: 100, accessedAt: 100, createdAt: 100, fileType: "bin", scanSessionId: sid),
            FileNode(path: "/tmp/root/sub", name: "sub", parentPath: "/tmp/root", size: 200, isDirectory: true, scanSessionId: sid),
            FileNode(path: "/tmp/root/small.txt", name: "small.txt", parentPath: "/tmp/root", size: 100, isDirectory: false, modifiedAt: 100, accessedAt: 100, createdAt: 100, fileType: "txt", scanSessionId: sid),
        ]
        try await repo.insertFilesBatch(nodes)
        try await repo.completeScanSession(id: sid)
    }

    func testReadPathOrderingAndCaps() async throws {
        let url = uniqueDBURL()
        defer { cleanup(url) }
        try await seed(at: url)

        let reader = try DiskSightReader(databaseURL: url)

        // scan_status reflects the completed session.
        let status = try reader.scanStatus()
        XCTAssertTrue(status.hasIndex)
        XCTAssertEqual(status.rootPath, "/tmp/root")
        XCTAssertEqual(status.fileCount, 2)        // non-directory files only
        XCTAssertEqual(status.totalSizeBytes, 5300) // root(0)+big(5000)+sub(200)+small(100)
        XCTAssertFalse(status.scanInProgress)

        // top_paths ordered by size desc.
        let top = try reader.topPaths(path: "/tmp/root", limit: 10)
        XCTAssertEqual(top.map(\.name), ["big.bin", "sub", "small.txt"])

        // limit cap: an absurd limit is clamped to <= 100.
        let capped = try reader.topPaths(path: "/tmp/root", limit: 100_000)
        XCTAssertLessThanOrEqual(capped.count, 100)

        // bloat_report: largest first.
        let bloat = try reader.bloatReport(largestLimit: 10, duplicateLimit: 10)
        XCTAssertEqual(bloat.largestFiles.first?.name, "big.bin")

        // search_files: name substring match.
        let hits = try reader.searchFiles(query: "big", limit: 10)
        XCTAssertEqual(hits.first?.name, "big.bin")

        // stale_files: big/small accessed in 1970 → stale vs a 1-year threshold.
        let stale = try reader.staleFiles(threshold: "1 Year", minSizeBytes: 1, limit: 10)
        XCTAssertTrue(stale.contains { $0.name == "big.bin" })
    }

    func testReadOnlyOpenPerformsNoWrites() async throws {
        let url = uniqueDBURL()
        defer { cleanup(url) }
        try await seed(at: url)

        // Snapshot the migration ledger and main file size.
        func migrationCount() throws -> Int {
            let probe = try Database(readOnlyURL: url)
            return try probe.dbPool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? -1
            }
        }
        let migrationsBefore = try migrationCount()
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int

        // Exercise the reader.
        let reader = try DiskSightReader(databaseURL: url)
        _ = try reader.scanStatus()
        _ = try reader.bloatReport()
        _ = try reader.topPaths(limit: 5)

        // No migration ran; main db file unchanged.
        XCTAssertEqual(try migrationCount(), migrationsBefore)
        let sizeAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertEqual(sizeBefore, sizeAfter)

        // The read-only handle physically rejects writes (SQLITE_OPEN_READONLY).
        // Attempt the write inside a `.read` so we exercise a real connection
        // without tripping GRDB's readonly-pool `.write` precondition.
        let ro = try Database(readOnlyURL: url)
        var writeRejected = false
        do {
            try await ro.dbPool.read { db in
                try db.execute(sql: "INSERT INTO files (path, name, size, is_directory) VALUES ('/x', 'x', 0, 0)")
            }
        } catch {
            writeRejected = true
        }
        XCTAssertTrue(writeRejected, "read-only handle must reject writes")
    }

    func testNoIndexThrows() throws {
        let url = uniqueDBURL() // never created
        XCTAssertThrowsError(try DiskSightReader(databaseURL: url)) { error in
            XCTAssertTrue(error is DiskSightReaderError)
        }
    }

    /// The sargable prefix delete must remove a directory + all descendants,
    /// spare prefix-siblings (e.g. deleting /a must NOT touch /ab or /a-x), and
    /// handle wildcard chars (% _) in names safely.
    func testRecursiveDeleteIsPrefixSafe() async throws {
        let url = uniqueDBURL()
        defer { cleanup(url) }
        let db = try Database(databaseURL: url)
        let repo = FileRepository(database: db)
        let session = try await repo.createScanSession(rootPath: "/")
        let sid = try XCTUnwrap(session.id)

        func node(_ p: String, dir: Bool = false) -> FileNode {
            FileNode(path: p, name: (p as NSString).lastPathComponent, parentPath: (p as NSString).deletingLastPathComponent, size: 1, isDirectory: dir, scanSessionId: sid)
        }
        let all = [
            "/a", "/a/b.txt", "/a/sub", "/a/sub/c.txt", "/a/100%_x.txt",  // /a + descendants → deleted
            "/ab.txt", "/a-x.txt", "/abc/d.txt", "/b.txt",                // prefix-siblings / others → kept
        ]
        try await repo.insertFilesBatch(all.map { node($0, dir: $0.hasSuffix("a") || $0.hasSuffix("sub")) })

        try await repo.deleteFilesRecursive(paths: ["/a"])

        let remaining = Set(try await repo.allFiles(forSession: sid).map(\.path))
        XCTAssertEqual(remaining, ["/ab.txt", "/a-x.txt", "/abc/d.txt", "/b.txt"],
                       "must delete /a and all descendants while sparing prefix-siblings")
    }
}
