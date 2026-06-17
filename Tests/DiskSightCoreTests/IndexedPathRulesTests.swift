import XCTest
@testable import DiskSightCore

final class IndexedPathRulesTests: XCTestCase {

    /// A non-root scan watches its root directly — behavior must be unchanged.
    func testNonRootScanWatchesRootDirectly() {
        let roots = IndexedPathRules.monitorWatchRoots(
            forScanRoot: "/Users/me/Projects",
            homeDirectory: "/Users/me"
        )
        XCTAssertEqual(roots, ["/Users/me/Projects"])
    }

    /// A root ("/") scan must NOT watch "/" itself (that's the firehose); it
    /// scopes to existing user areas, and home is always included when present.
    func testRootScanScopesToUserAreasNotRoot() {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.path   // guaranteed to exist
        let roots = IndexedPathRules.monitorWatchRoots(forScanRoot: "/", homeDirectory: home)

        XCTAssertFalse(roots.isEmpty)
        XCTAssertFalse(roots.contains("/"), "root scan must not watch / itself")
        XCTAssertTrue(roots.contains(home), "home directory should be watched")
        XCTAssertTrue(roots.allSatisfy { fm.fileExists(atPath: $0) },
                      "every watched root must actually exist")
    }

    /// Non-existent candidate dirs are filtered out (no watching of phantom paths).
    func testRootScanFiltersNonexistentHome() {
        let roots = IndexedPathRules.monitorWatchRoots(
            forScanRoot: "/",
            homeDirectory: "/definitely/not/a/real/home-\(UUID().uuidString)"
        )
        XCTAssertFalse(roots.contains { $0.contains("not/a/real/home") },
                       "a non-existent home must not be added to the watch list")
    }

    /// A "/" passed with trailing normalization still counts as a root scan.
    func testTrailingSlashRootIsTreatedAsRoot() {
        let roots = IndexedPathRules.monitorWatchRoots(
            forScanRoot: "/",
            homeDirectory: FileManager.default.temporaryDirectory.path
        )
        XCTAssertNotEqual(roots, ["/"], "a real user area should replace the bare root")
    }
}
