import SwiftUI
import Combine
import UniformTypeIdentifiers

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case visualization = "Visualization"
    case duplicates = "Duplicates"
    case staleFiles = "Stale Files"
    case cache = "Cache"
    case smartCleanup = "Smart Cleanup"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .visualization: return "square.grid.3x3.fill"
        case .duplicates: return "doc.on.doc"
        case .staleFiles: return "clock.arrow.circlepath"
        case .cache: return "internaldrive"
        case .smartCleanup: return "wand.and.stars"
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

    /// Incremented each time FSEvents batch processing completes.
    /// Views can observe this to refresh stale data (e.g., folder tree sizes).
    @Published var dataVersion: Int = 0

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

    // Smart Cleanup
    @Published var cleanupRecommendations: [CleanupRecommendation]?
    @Published var cleanupSummary: CleanupSummary?
    @Published var cleanupProgress: ClassificationProgress?
    @Published var isAnalyzingCleanup: Bool = false
    @Published var isOllamaAvailable: Bool = false
    @Published var ollamaModels: [String] = []
    @Published var selectedOllamaModel: String = ""

    private var scanTask: Task<Void, Never>?
    private let database: Database
    let fileRepository: FileRepository
    private var fsMonitor: FSEventsMonitor?
    private var eventCancellable: AnyCancellable?
    private var batchCancellable: AnyCancellable?
    private var rescanCancellable: AnyCancellable?
    private var terminationObserver: Any?

    init() {
        self.database = Database.shared
        self.fileRepository = FileRepository(database: database)
        checkFullDiskAccess()
        loadLastSession()

        // Save event ID synchronously on app quit — can't await in notification handlers
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.saveEventIdSync()
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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

        // Collect events in 2-second windows for the UI event log.
        // This prevents thousands of individual @Published updates from flooding
        // the main thread during bulk operations like rm -rf.
        eventCancellable = monitor.eventSubject
            .collect(.byTime(DispatchQueue.main, .seconds(2)))
            .sink { [weak self] events in
                guard let self, !events.isEmpty else { return }
                // Take only the most recent events to cap the list
                let newEvents = Array(events.suffix(50))
                self.recentEvents = (newEvents + self.recentEvents).prefix(50).map { $0 }
            }

        // Cache invalidation + viz refresh fires ONCE per processed batch,
        // not per individual event. This is what fixes the beachball — previously
        // each of N events triggered invalidateCache() + refreshVisualizationData().
        batchCancellable = monitor.batchProcessedSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.invalidateCache()
                self.dataVersion += 1
                Task { await self.refreshVisualizationData() }

                // Persist latest event ID for crash recovery
                if let monitor = self.fsMonitor,
                   let session = self.lastScanSession, let sessionId = session.id {
                    let eventId = monitor.currentEventId
                    Task {
                        try? await self.fileRepository.updateEventId(
                            sessionId: sessionId,
                            eventId: Int64(eventId)
                        )
                    }
                }
            }

        // Subscribe to rescan requests (MustScanSubDirs)
        rescanCancellable = monitor.rescanSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.triggerQuickRescan()
            }

        // Resume from last event ID if available
        let sinceId: UInt64
        if let lastId = lastScanSession?.lastFseventsId {
            sinceId = UInt64(lastId)
        } else {
            sinceId = UInt64(kFSEventStreamEventIdSinceNow)
        }

        // Check for stale event ID: if scan completed >7 days ago, the FSEvents
        // journal may have expired. Trigger a rescan instead of replaying from
        // a potentially invalid event ID.
        if let completedAt = lastScanSession?.completedAt {
            let sevenDaysAgo = Date().timeIntervalSince1970 - (7 * 24 * 60 * 60)
            if completedAt < sevenDaysAgo {
                triggerQuickRescan()
                return
            }
        }

        monitor.start(path: path, sinceEventId: sinceId)
        isMonitoring = true
    }

    func stopMonitoring() {
        // Save current event ID synchronously before stopping
        saveEventIdSync()

        fsMonitor?.stop()
        fsMonitor = nil
        eventCancellable = nil
        batchCancellable = nil
        rescanCancellable = nil
        isMonitoring = false
    }

    /// Synchronous event ID save — safe to call from notification handlers and deinit
    nonisolated func saveEventIdSync() {
        // Access MainActor-isolated properties requires careful handling.
        // We capture what we need assuming this is called from main thread contexts
        // (willTerminate, stopMonitoring). The nonisolated attribute is needed for
        // the notification handler signature.
        MainActor.assumeIsolated {
            guard let monitor = fsMonitor, let session = lastScanSession, let sessionId = session.id else { return }
            let eventId = monitor.currentEventId
            fileRepository.updateEventIdSync(sessionId: sessionId, eventId: Int64(eventId))
        }
    }

    /// Trigger a full rescan of the monitored path. Called when MustScanSubDirs
    /// is detected or when the saved event ID is likely stale.
    private func triggerQuickRescan() {
        guard let rootPath = scanRootPath else { return }
        startScan(at: rootPath)
    }

    /// Called when the app returns to the foreground. Restarts monitoring if
    /// the FSEvents stream died. Cache invalidation happens naturally via
    /// the FSEvents sink when real changes are detected.
    func handleBecameActive() {
        if let rootPath = lastScanSession?.rootPath, !(fsMonitor?.running ?? false) {
            startMonitoring(path: rootPath)
        }
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
            if let root = try fileRepository.rootNodeConcurrent() {
                overviewTopFolders = try fileRepository.childrenWithSizesConcurrent(ofPath: root.path)
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
            if let currentPath = vizCurrentPath {
                // Reload data for current drill-down position (preserves navigation after cache invalidation)
                vizChildNodes = try fileRepository.childrenWithSizesConcurrent(ofPath: currentPath)
            } else if let root = try fileRepository.rootNodeConcurrent() {
                // First load — navigate to root
                vizCurrentPath = root.path
                vizChildNodes = try fileRepository.childrenWithSizesConcurrent(ofPath: root.path)
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
            vizChildNodes = try fileRepository.childrenWithSizesConcurrent(ofPath: node.path)
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
            vizChildNodes = try fileRepository.childrenWithSizesConcurrent(ofPath: crumb.path)
        } catch {
            vizChildNodes = []
        }
    }

    /// Navigate to an arbitrary path, rebuilding breadcrumbs from the scan root down.
    /// Used by the folder tree sidebar to jump multiple levels at once.
    func vizNavigateToPath(_ targetPath: String) async {
        guard let rootPath = try? fileRepository.rootNodeConcurrent()?.path else { return }

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
            vizChildNodes = try fileRepository.childrenWithSizesConcurrent(ofPath: targetPath)
        } catch {
            vizChildNodes = []
        }
    }

    func vizNavigateToRoot() async {
        vizBreadcrumbs = []
        vizCurrentPath = nil
        // Use refreshVisualizationData which fetches root children
        // (loadVisualizationRoot would no-op since vizChildNodes isn't empty)
        await refreshVisualizationData()
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

    // MARK: - Smart Cleanup

    func loadSmartCleanup() async {
        guard cleanupRecommendations == nil else { return }
        guard let session = lastScanSession, let sessionId = session.id else { return }
        do {
            let records = try await fileRepository.recommendations(forSession: sessionId)
            guard !records.isEmpty else { return } // Leave nil so view shows "Analyze" prompt
            cleanupRecommendations = records.map { $0.toRecommendation() }
            cleanupSummary = try await fileRepository.recommendationSummary(forSession: sessionId)
        } catch {}
    }

    func runSmartCleanup(useLLM: Bool = false) async {
        guard let session = lastScanSession, let sessionId = session.id else { return }
        isAnalyzingCleanup = true
        cleanupRecommendations = nil
        cleanupSummary = nil
        cleanupProgress = ClassificationProgress(processed: 0, total: 0, currentFile: "Loading files...")

        do {
            // Clear previous recommendations
            try await fileRepository.deleteRecommendations(forSession: sessionId)

            let service = SmartCleanupService(
                classifier: FileClassifier(),
                repository: fileRepository,
                ollamaClient: useLLM ? OllamaClient() : nil
            )

            var allRecs: [CleanupRecommendation] = []
            let stream = await service.analyze(sessionId: sessionId, useLLM: useLLM)
            for await (progress, recs) in stream {
                cleanupProgress = progress
                // The service yields batches, then optionally a full enhanced set at the end.
                // If a yield contains all files (progress.processed == progress.total and
                // recs.count matches total so far), treat it as a replacement.
                if progress.processed == progress.total && recs.count == allRecs.count {
                    allRecs = recs
                } else {
                    allRecs.append(contentsOf: recs)
                }
                // Show partial results immediately
                cleanupRecommendations = allRecs
            }

            // Persist to DB
            let records = allRecs.map { CleanupRecommendationRecord.from($0) }
            let batchSize = 500
            for batchStart in stride(from: 0, to: records.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, records.count)
                try await fileRepository.insertRecommendations(Array(records[batchStart..<batchEnd]))
            }

            cleanupRecommendations = allRecs
            cleanupSummary = try await fileRepository.recommendationSummary(forSession: sessionId)
        } catch {}

        isAnalyzingCleanup = false
        cleanupProgress = nil
    }

    func checkOllamaStatus() async {
        let client = OllamaClient()
        let status = await client.checkAvailability()
        switch status {
        case .available(let models):
            isOllamaAvailable = true
            ollamaModels = models
            if selectedOllamaModel.isEmpty, let first = models.first {
                selectedOllamaModel = first
            }
        case .unavailable:
            isOllamaAvailable = false
            ollamaModels = []
        }
    }

    func trashCleanupFile(at path: String) async {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        try? await fileRepository.deleteFile(path: path)

        // Remove from local recommendations
        cleanupRecommendations?.removeAll { $0.filePath == path }
        if let session = lastScanSession, let sessionId = session.id {
            cleanupSummary = try? await fileRepository.recommendationSummary(forSession: sessionId)
        }
        invalidateCache()
        await refreshVisualizationData()
    }

    func trashAllSafeCleanup() async {
        guard let recs = cleanupRecommendations?.filter({ $0.confidence == .safe }) else { return }
        for rec in recs {
            let url = URL(fileURLWithPath: rec.filePath)
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            try? await fileRepository.deleteFile(path: rec.filePath)
        }
        cleanupRecommendations?.removeAll { $0.confidence == .safe }
        if let session = lastScanSession, let sessionId = session.id {
            cleanupSummary = try? await fileRepository.recommendationSummary(forSession: sessionId)
        }
        invalidateCache()
        await refreshVisualizationData()
    }

    func invalidateCache() {
        overviewFileCount = nil
        overviewTotalSize = nil
        overviewTopFolders = nil
        // vizChildNodes is NOT cleared here — clearing it causes a blank frame
        // because the view shows the empty state before the reload completes.
        // Instead, refreshVisualizationData() replaces the data atomically.
        // vizCurrentPath and vizBreadcrumbs are navigation state, not cached data.
        duplicateGroups = nil
        staleFiles = nil
        detectedCaches = nil
        cleanupRecommendations = nil
        cleanupSummary = nil
    }

    /// Reload viz data in-place without clearing first (prevents blank frame flicker)
    func refreshVisualizationData() async {
        do {
            if let currentPath = vizCurrentPath {
                vizChildNodes = try fileRepository.childrenWithSizesConcurrent(ofPath: currentPath)
            } else if let root = try fileRepository.rootNodeConcurrent() {
                vizCurrentPath = root.path
                vizChildNodes = try fileRepository.childrenWithSizesConcurrent(ofPath: root.path)
            }
        } catch {}
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
