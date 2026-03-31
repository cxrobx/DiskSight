import XCTest
@testable import DiskSight

final class SyncCompletionGatingTests: XCTestCase {
    func testSyncCompletionFailsWhenCancelled() {
        let progress = ScanProgress(
            filesScanned: 12,
            totalSize: 4096,
            currentPath: "/tmp",
            completed: true
        )

        XCTAssertFalse(
            AppState.syncCompletedSuccessfully(
                taskIsCancelled: true,
                lastProgress: progress
            )
        )
    }

    func testSyncCompletionRequiresCompletedProgress() {
        let progress = ScanProgress(
            filesScanned: 12,
            totalSize: 4096,
            currentPath: "/tmp",
            completed: false
        )

        XCTAssertFalse(
            AppState.syncCompletedSuccessfully(
                taskIsCancelled: false,
                lastProgress: progress
            )
        )
    }

    func testSyncCompletionSucceedsWhenProgressCompletedAndNotCancelled() {
        let progress = ScanProgress(
            filesScanned: 12,
            totalSize: 4096,
            currentPath: "/tmp",
            completed: true
        )

        XCTAssertTrue(
            AppState.syncCompletedSuccessfully(
                taskIsCancelled: false,
                lastProgress: progress
            )
        )
    }

    func testIsTestEnvironmentDetectsHostedXCTestBundle() {
        XCTAssertTrue(
            AppState.isTestEnvironment([
                "XCTestBundlePath": "Contents/PlugIns/DiskSightTests.xctest",
                "XCTestConfigurationFilePath": ""
            ])
        )
    }

    func testIsTestEnvironmentIgnoresNormalAppEnvironment() {
        XCTAssertFalse(
            AppState.isTestEnvironment([
                "PATH": "/usr/bin:/bin",
                "HOME": "/tmp"
            ])
        )
    }

    func testPseudoFilesystemPathsAreExcludedDuringFilesystemRootScans() {
        XCTAssertTrue(IndexedPathRules.shouldExcludeDuringRootScan(path: "/dev/fd", scanRootPath: "/"))
        XCTAssertTrue(IndexedPathRules.shouldExcludeDuringRootScan(path: "/dev/fd/3", scanRootPath: "/"))
        XCTAssertFalse(IndexedPathRules.shouldExcludeDuringRootScan(path: "/Users/christopherrobinson", scanRootPath: "/"))
        XCTAssertFalse(IndexedPathRules.shouldExcludeDuringRootScan(path: "/dev/fd", scanRootPath: "/Users/christopherrobinson"))
    }

    func testShouldDisplayGrowthFolderRejectsPseudoFilesystemPaths() {
        XCTAssertFalse(
            AppState.shouldDisplayGrowthFolder(at: "/dev/fd") { _ in true }
        )
    }

    func testSanitizeGrowthFoldersDropsMissingAndPseudoFilesystemPaths() {
        let folders = [
            FolderGrowth(
                folderPath: "/tmp/keep",
                folderName: "keep",
                totalFolderSize: 10,
                recentGrowthSize: 5,
                recentFileCount: 1
            ),
            FolderGrowth(
                folderPath: "/tmp/missing",
                folderName: "missing",
                totalFolderSize: 20,
                recentGrowthSize: 10,
                recentFileCount: 2
            ),
            FolderGrowth(
                folderPath: "/dev/fd",
                folderName: "fd",
                totalFolderSize: 0,
                recentGrowthSize: 30,
                recentFileCount: 3
            )
        ]

        let sanitized = AppState.sanitizeGrowthFolders(folders) { path in
            path == "/tmp/keep"
        }

        XCTAssertEqual(sanitized.map(\.folderPath), ["/tmp/keep"])
    }
}
