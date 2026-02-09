import Foundation
import GRDB

enum CacheSafety: String, Codable {
    case green  // Safe to delete, will regenerate
    case yellow // Probably safe, but may require re-download or rebuild
    case red    // Risky, may cause data loss

    var label: String {
        switch self {
        case .green: return "Safe"
        case .yellow: return "Caution"
        case .red: return "Risky"
        }
    }
}

struct CachePattern: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var pattern: String
    var category: String
    var safety: String
    var description: String?

    static let databaseTableName = "cache_patterns"

    var safetyLevel: CacheSafety {
        CacheSafety(rawValue: safety) ?? .yellow
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct DetectedCache: Identifiable {
    let id = UUID()
    let pattern: CachePattern
    let matchedPaths: [String]
    let totalSize: Int64
}

actor CacheDetector {
    private let repository: FileRepository

    init(repository: FileRepository) {
        self.repository = repository
    }

    func seedDefaultPatterns() async throws {
        let existing = try await repository.cachePatternCount()
        guard existing == 0 else { return }

        let defaults: [(String, String, String, String)] = [
            ("~/Library/Caches/*", "System", "green", "System and app caches — safe to clear, will regenerate"),
            ("~/Library/Developer/Xcode/DerivedData", "Developer", "yellow", "Xcode build artifacts — safe but requires rebuild"),
            ("**/node_modules", "Developer", "yellow", "npm/yarn packages — safe but requires reinstall"),
            ("~/.gradle/caches", "Developer", "yellow", "Gradle build cache — safe but requires rebuild"),
            ("~/.cargo/registry/cache", "Developer", "yellow", "Rust crate cache — safe but requires re-download"),
            ("~/.m2/repository", "Developer", "yellow", "Maven repository — safe but requires re-download"),
            ("~/Library/Caches/Homebrew", "Package Manager", "green", "Homebrew download cache — safe to clear"),
            ("**/.venv", "Developer", "yellow", "Python virtual environments — safe but requires recreate"),
            ("~/.cache/pip", "Package Manager", "green", "pip download cache — safe to clear"),
            ("~/Library/Application Support/Code/CachedData", "Developer", "green", "VS Code cache — safe to clear"),
        ]

        try await repository.insertCachePatterns(defaults)
    }

    func detectCaches() async throws -> [DetectedCache] {
        try await seedDefaultPatterns()

        let patterns = try await repository.allCachePatterns()
        var results: [DetectedCache] = []

        for pattern in patterns {
            let expandedPattern = expandPattern(pattern.pattern)
            let (paths, size) = try await findMatchingPaths(expandedPattern)

            if !paths.isEmpty {
                results.append(DetectedCache(
                    pattern: pattern,
                    matchedPaths: paths,
                    totalSize: size
                ))
            }
        }

        return results.sorted { $0.totalSize > $1.totalSize }
    }

    private func expandPattern(_ pattern: String) -> String {
        pattern.replacingOccurrences(of: "~", with: NSHomeDirectory())
    }

    private func findMatchingPaths(_ pattern: String) async throws -> ([String], Int64) {
        // For glob patterns, search the DB for matching paths
        let searchPattern = pattern
            .replacingOccurrences(of: "**", with: "%")
            .replacingOccurrences(of: "*", with: "%")

        return try await repository.matchingPaths(likePattern: searchPattern)
    }
}
