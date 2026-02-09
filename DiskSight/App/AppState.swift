import SwiftUI
import Combine

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case visualization = "Visualization"
    case duplicates = "Duplicates"
    case staleFiles = "Stale Files"
    case cache = "Cache"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .visualization: return "square.grid.3x3.fill"
        case .duplicates: return "doc.on.doc"
        case .staleFiles: return "clock.arrow.circlepath"
        case .cache: return "internaldrive"
        }
    }
}

enum ScanState: Equatable {
    case idle
    case scanning(progress: ScanProgress)
    case completed
    case error(String)

    static func == (lhs: ScanState, rhs: ScanState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.completed, .completed): return true
        case (.scanning(let a), .scanning(let b)): return a.filesScanned == b.filesScanned
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

struct ScanProgress: Sendable {
    var filesScanned: Int = 0
    var totalSize: Int64 = 0
    var currentPath: String = ""
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedSection: SidebarSection = .overview
    @Published var scanState: ScanState = .idle
    @Published var scanRootPath: URL?
    @Published var lastScanSession: ScanSession?
    @Published var hasFullDiskAccess: Bool = false

    private var scanTask: Task<Void, Never>?
    private let database: Database
    let fileRepository: FileRepository

    init() {
        self.database = Database.shared
        self.fileRepository = FileRepository(database: database)
        checkFullDiskAccess()
    }

    func checkFullDiskAccess() {
        let testPath = NSHomeDirectory() + "/Library/Mail"
        hasFullDiskAccess = FileManager.default.isReadableFile(atPath: testPath)
    }

    func startScan(at url: URL) {
        scanTask?.cancel()
        scanState = .scanning(progress: ScanProgress())

        scanTask = Task {
            do {
                let scanner = FileScanner(repository: fileRepository)
                let session = try await fileRepository.createScanSession(rootPath: url.path)

                for await progress in scanner.scan(rootURL: url, sessionId: session.id!) {
                    self.scanState = .scanning(progress: progress)
                }

                try await fileRepository.completeScanSession(id: session.id!)
                self.lastScanSession = try await fileRepository.latestScanSession()
                self.scanState = .completed
            } catch {
                if !Task.isCancelled {
                    self.scanState = .error(error.localizedDescription)
                }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanState = .idle
    }
}
