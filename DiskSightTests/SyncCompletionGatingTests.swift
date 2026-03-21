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
}
