import SwiftUI
import Combine
import UniformTypeIdentifiers

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

    // MARK: - Cached Data (survives tab switches)

    // Overview
    @Published var overviewFileCount: Int?
    @Published var overviewTotalSize: Int64?
    @Published var overviewTopFolders: [FileNode]?

    // Visualization
    @Published var vizChildNodes: [FileNode] = []
    @Published var vizCurrentPath: String?
    @Published var vizBreadcrumbs: [BreadcrumbItem] = []

    // Duplicates
    @Published var duplicateGroups: [DuplicateGroup]?

    // Stale Files
    @Published var staleFiles: [FileNode]?
    @Published var staleThreshold: StaleThreshold = .oneYear

    // Cache
    @Published var detectedCaches: [DetectedCache]?

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
        invalidateCache()
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

        // Subscribe to events for UI updates + cache invalidation
        eventCancellable = monitor.eventSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.recentEvents.insert(event, at: 0)
                if (self?.recentEvents.count ?? 0) > 50 {
                    self?.recentEvents = Array(self?.recentEvents.prefix(50) ?? [])
                }
                self?.invalidateCache()
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

    // MARK: - Export

    func exportCSV() {
        guard let session = lastScanSession, let sessionId = session.id else { return }

        Task {
            let files = try await fileRepository.allFiles(forSession: sessionId)
            let csv = CSVExporter.generate(from: files)

            let panel = NSSavePanel()
            panel.title = "Export Scan as CSV"
            panel.nameFieldStringValue = "DiskSight-Export.csv"
            panel.allowedContentTypes = [.commaSeparatedText]

            guard panel.runModal() == .OK, let url = panel.url else { return }

            try csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Cached Data Loading

    func loadOverviewData() async {
        guard overviewFileCount == nil else { return }
        do {
            overviewFileCount = try await fileRepository.fileCount()
            overviewTotalSize = try await fileRepository.totalSize()
            if let root = try await fileRepository.rootNode() {
                overviewTopFolders = try await fileRepository.childrenWithSizes(ofPath: root.path)
                    .filter { $0.isDirectory }
                    .prefix(10)
                    .map { $0 }
            }
            if lastScanSession == nil {
                lastScanSession = try await fileRepository.latestScanSession()
            }
        } catch {}
    }

    func loadVisualizationRoot() async {
        guard vizChildNodes.isEmpty else { return }
        do {
            if let root = try await fileRepository.rootNode() {
                vizCurrentPath = root.path
                vizChildNodes = try await fileRepository.childrenWithSizes(ofPath: root.path)
                vizBreadcrumbs = []
            }
        } catch {}
    }

    func vizDrillDown(to node: FileNode) async {
        guard node.isDirectory else { return }

        if let currentPath = vizCurrentPath {
            let name = vizBreadcrumbs.isEmpty
                ? (scanRootPath?.lastPathComponent ?? "Root")
                : URL(fileURLWithPath: currentPath).lastPathComponent
            if !vizBreadcrumbs.contains(where: { $0.path == currentPath }) {
                vizBreadcrumbs.append(BreadcrumbItem(id: currentPath, name: name, path: currentPath))
            }
        }

        vizCurrentPath = node.path
        do {
            vizChildNodes = try await fileRepository.childrenWithSizes(ofPath: node.path)
        } catch {
            vizChildNodes = []
        }
    }

    func vizNavigateTo(_ crumb: BreadcrumbItem) async {
        if let index = vizBreadcrumbs.firstIndex(where: { $0.id == crumb.id }) {
            vizBreadcrumbs = Array(vizBreadcrumbs.prefix(index))
        }

        vizCurrentPath = crumb.path
        do {
            vizChildNodes = try await fileRepository.childrenWithSizes(ofPath: crumb.path)
        } catch {
            vizChildNodes = []
        }
    }

    /// Navigate to an arbitrary path, rebuilding breadcrumbs from the scan root down.
    /// Used by the folder tree sidebar to jump multiple levels at once.
    func vizNavigateToPath(_ targetPath: String) async {
        guard let rootPath = try? await fileRepository.rootNode()?.path else { return }

        // If navigating to root, just reset
        if targetPath == rootPath {
            await vizNavigateToRoot()
            return
        }

        // Rebuild breadcrumbs from root to parent of target
        var crumbs: [BreadcrumbItem] = []
        let rootURL = URL(fileURLWithPath: rootPath)
        let targetURL = URL(fileURLWithPath: targetPath)

        // Walk from root to target, building ancestor breadcrumbs
        var currentURL = rootURL
        let rootName = scanRootPath?.lastPathComponent ?? rootURL.lastPathComponent
        crumbs.append(BreadcrumbItem(id: rootPath, name: rootName, path: rootPath))

        // Get relative path components from root to target
        let rootStd = rootURL.standardizedFileURL.path
        let targetStd = targetURL.standardizedFileURL.path
        let prefix = rootStd.hasSuffix("/") ? rootStd : rootStd + "/"

        if targetStd.hasPrefix(prefix) {
            let relative = String(targetStd.dropFirst(prefix.count))
            let components = relative.split(separator: "/")

            // Add breadcrumbs for each ancestor (excluding the target itself)
            for i in 0..<components.count {
                currentURL = currentURL.appendingPathComponent(String(components[i]))
                let ancestorPath = currentURL.path
                if ancestorPath != targetPath {
                    crumbs.append(BreadcrumbItem(
                        id: ancestorPath,
                        name: String(components[i]),
                        path: ancestorPath
                    ))
                }
            }
        }

        vizBreadcrumbs = crumbs
        vizCurrentPath = targetPath
        do {
            vizChildNodes = try await fileRepository.childrenWithSizes(ofPath: targetPath)
        } catch {
            vizChildNodes = []
        }
    }

    func vizNavigateToRoot() async {
        vizBreadcrumbs = []
        vizChildNodes = []
        vizCurrentPath = nil
        await loadVisualizationRoot()
    }

    func loadStaleFiles(threshold: StaleThreshold) async {
        if staleFiles != nil && staleThreshold == threshold { return }
        staleThreshold = threshold
        let finder = StaleFinder(repository: fileRepository)
        staleFiles = (try? await finder.findStaleFiles(threshold: threshold)) ?? []
    }

    func loadCacheData() async {
        guard detectedCaches == nil else { return }
        let detector = CacheDetector(repository: fileRepository)
        detectedCaches = (try? await detector.detectCaches()) ?? []
    }

    func invalidateCache() {
        overviewFileCount = nil
        overviewTotalSize = nil
        overviewTopFolders = nil
        vizChildNodes = []
        vizCurrentPath = nil
        vizBreadcrumbs = []
        duplicateGroups = nil
        staleFiles = nil
        detectedCaches = nil
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
