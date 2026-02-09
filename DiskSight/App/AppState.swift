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
    @Published var isMonitoring: Bool = false
    @Published var recentEvents: [FSEventInfo] = []

    private var scanTask: Task<Void, Never>?
    private let database: Database
    let fileRepository: FileRepository
    private var fsMonitor: FSEventsMonitor?
    private var eventCancellable: AnyCancellable?

    init() {
        self.database = Database.shared
        self.fileRepository = FileRepository(database: database)
        checkFullDiskAccess()
        loadLastSession()
    }

    func checkFullDiskAccess() {
        let testPath = NSHomeDirectory() + "/Library/Mail"
        hasFullDiskAccess = FileManager.default.isReadableFile(atPath: testPath)
    }

    func startScan(at url: URL) {
        scanTask?.cancel()
        stopMonitoring()
        scanState = .scanning(progress: ScanProgress())

        scanTask = Task {
            do {
                let scanner = FileScanner(repository: fileRepository)
                let session = try await fileRepository.createScanSession(rootPath: url.path)
                guard let sessionId = session.id else {
                    self.scanState = .error("Failed to create scan session")
                    return
                }

                for await progress in scanner.scan(rootURL: url, sessionId: sessionId) {
                    self.scanState = .scanning(progress: progress)
                }

                try await fileRepository.completeScanSession(id: sessionId)
                self.lastScanSession = try await fileRepository.latestScanSession()
                self.scanState = .completed

                // Start monitoring after scan completes
                startMonitoring(path: url.path)
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

    // MARK: - FSEvents Monitoring

    func startMonitoring(path: String) {
        stopMonitoring()

        let monitor = FSEventsMonitor(repository: fileRepository)
        self.fsMonitor = monitor

        // Subscribe to events for UI updates
        eventCancellable = monitor.eventSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.recentEvents.insert(event, at: 0)
                if (self?.recentEvents.count ?? 0) > 50 {
                    self?.recentEvents = Array(self?.recentEvents.prefix(50) ?? [])
                }
            }

        // Resume from last event ID if available
        let sinceId: UInt64
        if let lastId = lastScanSession?.lastFseventsId {
            sinceId = UInt64(lastId)
        } else {
            sinceId = UInt64(kFSEventStreamEventIdSinceNow)
        }

        monitor.start(path: path, sinceEventId: sinceId)
        isMonitoring = true
    }

    func stopMonitoring() {
        // Save current event ID before stopping
        if let monitor = fsMonitor, let session = lastScanSession, let sessionId = session.id {
            let eventId = monitor.currentEventId
            Task {
                try? await fileRepository.updateEventId(sessionId: sessionId, eventId: Int64(eventId))
            }
        }

        fsMonitor?.stop()
        fsMonitor = nil
        eventCancellable = nil
        isMonitoring = false
    }

    private func loadLastSession() {
        Task {
            self.lastScanSession = try? await fileRepository.latestScanSession()
            if let session = lastScanSession {
                self.scanRootPath = URL(fileURLWithPath: session.rootPath)
                if session.completedAt != nil {
                    self.scanState = .completed
                    startMonitoring(path: session.rootPath)
                }
            }
        }
    }
}
