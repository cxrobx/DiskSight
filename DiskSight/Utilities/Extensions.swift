import Foundation

enum IndexedPathRules {
    private static let pseudoFilesystemRoots = ["/dev"]

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
