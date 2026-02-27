import Foundation

enum GrowthPeriod: String, CaseIterable, Identifiable {
    case sevenDays = "7 Days"
    case fourteenDays = "14 Days"
    case thirtyDays = "30 Days"
    case ninetyDays = "90 Days"

    var id: String { rawValue }

    var timeInterval: TimeInterval {
        switch self {
        case .sevenDays: return 7 * 24 * 3600
        case .fourteenDays: return 14 * 24 * 3600
        case .thirtyDays: return 30 * 24 * 3600
        case .ninetyDays: return 90 * 24 * 3600
        }
    }

    var cutoffDate: Date {
        Date().addingTimeInterval(-timeInterval)
    }
}

struct FolderGrowth: Identifiable, Codable, Sendable {
    let folderPath: String
    let folderName: String
    let totalFolderSize: Int64
    let recentGrowthSize: Int64
    let recentFileCount: Int

    var id: String { folderPath }

    var growthProportion: Double {
        guard totalFolderSize > 0 else { return 0 }
        return min(1.0, Double(recentGrowthSize) / Double(totalFolderSize))
    }
}

actor GrowthFinder {
    private let repository: FileRepository

    init(repository: FileRepository) {
        self.repository = repository
    }

    func findGrowingFolders(period: GrowthPeriod, limit: Int = 50, excludePrefix: String? = nil) async throws -> [FolderGrowth] {
        let cutoff = period.cutoffDate.timeIntervalSince1970
        return try await repository.recentlyGrowingFolders(createdAfter: cutoff, limit: limit, excludePrefix: excludePrefix)
    }
}
