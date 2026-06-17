import Foundation

enum IndexedPathRules {
    private static let pseudoFilesystemRoots = ["/dev", "/.vol"]

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func isPseudoFilesystemPath(_ path: String) -> Bool {
        let normalized = normalizedPath(path)
        return pseudoFilesystemRoots.contains { root in
            normalized == root || normalized.hasPrefix(root + "/")
        }
    }

    static func shouldExcludeDuringRootScan(path: String, scanRootPath: String) -> Bool {
        normalizedPath(scanRootPath) == "/" && isPseudoFilesystemPath(path)
    }

    /// FSEvents watch roots for a given scan root.
    ///
    /// Watching all of `/` makes the kernel deliver a system-wide firehose
    /// (logs, `/private/var`, temp, diagnostics, per-app container churn) that
    /// can peg a CPU core even at idle. When the scan root is `/`, watch only
    /// the user-owned, high-value areas — the home directory and `/Applications`
    /// — so the system noise is never delivered in the first place. Any other
    /// scan root is watched directly (unchanged behavior).
    ///
    /// Changes *outside* the watched roots are still captured by a full or
    /// incremental rescan; they simply aren't reflected live.
    static func monitorWatchRoots(
        forScanRoot scanRoot: String,
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> [String] {
        guard normalizedPath(scanRoot) == "/" else { return [scanRoot] }

        let candidates = [homeDirectory, "/Applications"]
        let existing = candidates.filter { candidate in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        // Fall back to the root itself if neither user area exists (unusual), so
        // monitoring still functions rather than silently watching nothing.
        return existing.isEmpty ? [scanRoot] : existing
    }
}

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}

extension Date {
    var relativeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
