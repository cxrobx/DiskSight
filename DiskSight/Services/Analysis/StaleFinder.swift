import Foundation
import GRDB

enum StaleThreshold: String, CaseIterable, Identifiable {
    case sixMonths = "6 Months"
    case oneYear = "1 Year"
    case twoYears = "2 Years"
    case fiveYears = "5 Years"

    var id: String { rawValue }

    var timeInterval: TimeInterval {
        switch self {
        case .sixMonths: return 6 * 30 * 24 * 3600
        case .oneYear: return 365 * 24 * 3600
        case .twoYears: return 2 * 365 * 24 * 3600
        case .fiveYears: return 5 * 365 * 24 * 3600
        }
    }

    var cutoffDate: Date {
        Date().addingTimeInterval(-timeInterval)
    }
}

actor StaleFinder {
    private let repository: FileRepository

    init(repository: FileRepository) {
        self.repository = repository
    }

    func findStaleFiles(threshold: StaleThreshold, minSize: Int64 = 1_048_576) async throws -> [FileNode] {
        let cutoff = threshold.cutoffDate.timeIntervalSince1970
        return try await repository.staleFiles(accessedBefore: cutoff, minSize: minSize)
    }

    func staleFilesByFolder(threshold: StaleThreshold, minSize: Int64 = 1_048_576) async throws -> [(String, [FileNode])] {
        let files = try await findStaleFiles(threshold: threshold, minSize: minSize)
        var grouped: [String: [FileNode]] = [:]
        for file in files {
            let folder = file.parentPath ?? "/"
            grouped[folder, default: []].append(file)
        }
        return grouped.sorted { lhs, rhs in
            let lhsSize = lhs.value.reduce(0) { $0 + $1.size }
            let rhsSize = rhs.value.reduce(0) { $0 + $1.size }
            return lhsSize > rhsSize
        }
    }
}
