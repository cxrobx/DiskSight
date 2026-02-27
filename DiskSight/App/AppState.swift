import SwiftUI
import Combine
import UniformTypeIdentifiers

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case visualization = "Visualization"
    case growth = "Recent Growth"
    case duplicates = "Duplicates"
    case staleFiles = "Stale Files"
    case cache = "Cache"
    case smartCleanup = "Smart Cleanup"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .visualization: return "square.grid.3x3.fill"
        case .growth: return "chart.line.uptrend.xyaxis"
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
    var completed: Bool = false
}

@MainActor
final class AppState: ObservableObject {
    nonisolated static func syncCompletedSuccessfully(taskIsCancelled: Bool, lastProgress: ScanProgress?) -> Bool {
        guard !taskIsCancelled else { return false }
        return lastProgress?.completed ?? false
    }

    @Published var selectedSection: SidebarSection = .overview
    @Published var scanState: ScanState = .idle
    @Published var scanRootPath: URL?
    @Published var lastScanSession: ScanSession?
    @Published var hasFullDiskAccess: Bool = false
    @Published var isMonitoring: Bool = false
    @Published var recentEvents: [FSEventInfo] = []
    @Published var isExportingCSV: Bool = false
    @Published var csvExportDone: Bool = false
    @Published var isSyncing: Bool = false

    /// Incremented each time FSEvents batch processing completes.
    /// Views can observe this to refresh stale data (e.g., folder tree sizes).
    @Published var dataVersion: Int = 0
    @Published var hideExternalDrives: Bool = UserDefaults.standard.bool(forKey: "hideExternalDrives") {
        didSet {
            UserDefaults.standard.set(hideExternalDrives, forKey: "hideExternalDrives")
            Task { await refreshVisibilityFilteredData() }
        }
    }

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

    // Growth
    @Published var growthFolders: [FolderGrowth]?
    @Published var growthPeriod: GrowthPeriod = .thirtyDays
    @Published var growthLoadingPeriod: GrowthPeriod?
    private var growthCache: [GrowthPeriod: [FolderGrowth]] = [:]
    private var growthCacheDataVersion: Int = -1

    // Smart Cleanup
    @Published var cleanupRecommendations: [CleanupRecommendation]?
    @Published var cleanupSummary: CleanupSummary?
    @Published var cleanupProgress: ClassificationProgress?
    @Published var isAnalyzingCleanup: Bool = false
    @Published var isOllamaAvailable: Bool = false
    @Published var ollamaModels: [String] = []
    @Published var selectedOllamaModel: String = ""

    private var scanTask: Task<Void, Never>?
    private var incrementalSyncTask: Task<Void, Never>?
    private var cachePrefetchTask: Task<Void, Never>?
    private var growthPrefetchTask: Task<Void, Never>?
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
        scheduleCacheWarmup()
        scheduleGrowthWarmup()

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
        incrementalSyncTask?.cancel()
        cachePrefetchTask?.cancel()
        growthPrefetchTask?.cancel()
        stopMonitoring()

        // Reset viz state — full scan means starting fresh
        vizChildNodes = []
        vizCurrentPath = nil
        vizBreadcrumbs = []
        growthFolders = nil
        growthCache = [:]

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
                // Clean up files and sessions from previous scans
                try? await fileRepository.deleteFilesFromPreviousSessions(currentSessionId: sessionId)
                try? await fileRepository.deleteOldSessions(keepingId: sessionId)
                self.lastScanSession = try fileRepository.latestScanSession()
                self.scanState = .completed
                self.scheduleCacheWarmup()
                self.scheduleGrowthWarmup()

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
                    // Update in-memory session so handleBecameActive uses fresh event ID
                    self.lastScanSession?.lastFseventsId = Int64(eventId)
                    Task {
                        try? await self.fileRepository.updateEventId(
                            sessionId: sessionId,
                            eventId: Int64(eventId)
                        )
                    }
                }
            }

        // Subscribe to rescan requests (MustScanSubDirs).
        // Debounce: FSEvents replay can fire dozens of MustScanSubDirs callbacks in rapid
        // succession. Without debounce, each one cancels+restarts quickSync on main thread.
        rescanCancellable = monitor.rescanSubject
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
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
                // Start monitoring from "now" to capture new changes while sync runs
                monitor.start(path: path, sinceEventId: UInt64(kFSEventStreamEventIdSinceNow))
                isMonitoring = true
                // Full walk catches the gap since the last session (>7 days stale)
                runIncrementalSync(path: path, fullWalk: true)
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

    /// Trigger an incremental sync of the monitored path. Called when MustScanSubDirs
    /// is detected or when the saved event ID is likely stale.
    private func triggerQuickRescan() {
        guard let rootPath = scanRootPath else { return }
        // Skip if session is very fresh — FSEvents will catch any changes going forward.
        // MustScanSubDirs during initial replay doesn't mean data is stale; it just means
        // the kernel can't guarantee individual event paths.
        if let completedAt = lastScanSession?.completedAt {
            let fiveMinutesAgo = Date().timeIntervalSince1970 - 300
            if completedAt > fiveMinutesAgo { return }
        }
        runIncrementalSync(path: rootPath.path)
    }

    /// Background incremental sync — walks the filesystem and upserts only new/modified
    /// files, deletes removed ones. Does NOT change scanState, so the UI stays usable
    /// with existing viz data during the sync.
    /// - Parameter fullWalk: When true, uses iterative DFS without mtime pruning (for stale >7 day gaps).
    ///   When false (default), uses fast quickSync with mtime pruning.
    private func runIncrementalSync(path: String, fullWalk: Bool = false) {
        incrementalSyncTask?.cancel()
        guard let session = lastScanSession, let sessionId = session.id else { return }
        isSyncing = true

        incrementalSyncTask = Task(priority: .low) {
            let scanner = FileScanner(repository: fileRepository)
            let rootURL = URL(fileURLWithPath: path)
            var lastProgress: ScanProgress?

            if fullWalk {
                // >7 day stale path — full walk (iterative DFS, no mtime pruning)
                let stream = scanner.incrementalScan(rootURL: rootURL, sessionId: sessionId)
                for await progress in stream { lastProgress = progress }
            } else {
                // Normal path — fast quickSync with mtime pruning
                let since = session.completedAt ?? 0
                let stream = scanner.quickSync(rootURL: rootURL, since: since, sessionId: sessionId)
                for await progress in stream { lastProgress = progress }
            }

            // Only mark session fresh if sync completed successfully
            let syncSuccess = Self.syncCompletedSuccessfully(
                taskIsCancelled: Task.isCancelled,
                lastProgress: lastProgress
            )
            guard syncSuccess else {
                self.isSyncing = false
                return
            }
            try? await fileRepository.updateSessionStats(id: sessionId)
            self.lastScanSession = try? fileRepository.latestCompletedScanSession()
            self.invalidateCache()
            self.dataVersion += 1
            await self.refreshVisualizationData()
            self.isSyncing = false
        }
    }

    /// Called when the app returns to the foreground. Restarts monitoring if
    /// the FSEvents stream died. Cache invalidation happens naturally via
    /// the FSEvents sink when real changes are detected.
    func handleBecameActive() {
        // Only re-query if we have no session — avoids a redundant DB hit on every cmd-tab
        if lastScanSession == nil {
            if let session = try? fileRepository.latestCompletedScanSession() {
                self.lastScanSession = session
                self.scanRootPath = URL(fileURLWithPath: session.rootPath)
                scheduleCacheWarmup()
                scheduleGrowthWarmup()
            }
        }
        if let rootPath = lastScanSession?.rootPath, !(fsMonitor?.running ?? false) {
            startMonitoring(path: rootPath)
        }
    }

    // MARK: - Export

    func exportCSV() {
        guard let session = lastScanSession, let sessionId = session.id else { return }

        Task {
            let panel = NSSavePanel()
            panel.title = "Export Scan as CSV"
            panel.nameFieldStringValue = "DiskSight-Export.csv"
            panel.allowedContentTypes = [.commaSeparatedText]

            guard panel.runModal() == .OK, let url = panel.url else { return }

            isExportingCSV = true
            csvExportDone = false
            do {
                try await CSVExporter.stream(from: fileRepository, sessionId: sessionId, to: url)
                csvExportDone = true
                // Clear success indicator after 3 seconds
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self.csvExportDone = false
                }
            } catch {
                // Silently fail — file write errors are rare after NSSavePanel
            }
            isExportingCSV = false
        }
    }

    // MARK: - Cached Data Loading

    func loadOverviewData() async {
        guard overviewFileCount == nil else { return }
        do {
            if let session = lastScanSession, let sessionId = session.id {
                // Use pre-computed session stats — avoids full-table scan on cold launch
                if let count = session.fileCount {
                    overviewFileCount = count
                } else {
                    overviewFileCount = try fileRepository.fileCount(sessionId: sessionId)
                }
                if let indexed = session.indexedSize {
                    overviewTotalSize = indexed
                } else {
                    overviewTotalSize = try fileRepository.totalSize(sessionId: sessionId)
                }
                if let root = try fileRepository.rootNodeConcurrent() {
                    overviewTopFolders = visibleFileNodes(try fileRepository.childrenWithSizesConcurrent(ofPath: root.path))
                        .filter { $0.isDirectory }
                        .prefix(10)
                        .map { $0 }
                }
            } else {
                // No session yet (first launch / no scan) — resolve session then leave nils for empty state
                if lastScanSession == nil {
                    lastScanSession = try? fileRepository.latestCompletedScanSession()
                }
            }
        } catch {
            #if DEBUG
            print("[AppState] loadOverviewData error: \(error)")
            #endif
        }
    }

    func loadVisualizationRoot() async {
        guard vizChildNodes.isEmpty else { return }
        do {
            if let currentPath = vizCurrentPath, shouldIncludePath(currentPath) {
                // Reload data for current drill-down position (preserves navigation after cache invalidation)
                vizChildNodes = visibleFileNodes(try fileRepository.childrenWithSizesConcurrent(ofPath: currentPath))
            } else if let root = try fileRepository.rootNodeConcurrent() {
                // First load — navigate to root
                vizCurrentPath = root.path
                vizChildNodes = visibleFileNodes(try fileRepository.childrenWithSizesConcurrent(ofPath: root.path))
                vizBreadcrumbs = []
            }
        } catch {
            #if DEBUG
            print("[AppState] loadVisualizationRoot error: \(error)")
            #endif
        }
    }

    func vizDrillDown(to node: FileNode) async {
        guard node.isDirectory else { return }
        guard shouldIncludePath(node.path) else { return }

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
            vizChildNodes = visibleFileNodes(try fileRepository.childrenWithSizesConcurrent(ofPath: node.path))
        } catch {
            vizChildNodes = []
        }
    }

    func vizNavigateTo(_ crumb: BreadcrumbItem) async {
        guard shouldIncludePath(crumb.path) else {
            await vizNavigateToRoot()
            return
        }
        if let index = vizBreadcrumbs.firstIndex(where: { $0.id == crumb.id }) {
            vizBreadcrumbs = Array(vizBreadcrumbs.prefix(index))
        }

        vizCurrentPath = crumb.path
        do {
            vizChildNodes = visibleFileNodes(try fileRepository.childrenWithSizesConcurrent(ofPath: crumb.path))
        } catch {
            vizChildNodes = []
        }
    }

    /// Navigate to an arbitrary path, rebuilding breadcrumbs from the scan root down.
    /// Used by the folder tree sidebar to jump multiple levels at once.
    func vizNavigateToPath(_ targetPath: String) async {
        guard shouldIncludePath(targetPath) else {
            await vizNavigateToRoot()
            return
        }
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
                if ancestorPath != targetPath, shouldIncludePath(ancestorPath) {
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
            vizChildNodes = visibleFileNodes(try fileRepository.childrenWithSizesConcurrent(ofPath: targetPath))
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

    /// Synchronous period switch — instant for cache hits, spawns async load for misses.
    func switchGrowthPeriod(to period: GrowthPeriod) {
        ensureGrowthCacheFreshForCurrentDataVersion()
        growthPeriod = period
        if let cached = growthCache[period] {
            growthFolders = visibleGrowthFolders(cached)
            growthLoadingPeriod = nil
            return
        }
        growthLoadingPeriod = period
        growthFolders = nil
        // Cache miss — load in background
        Task {
            let results = await loadGrowthPeriod(period, forceRefresh: false)
            if growthPeriod == period {
                growthFolders = visibleGrowthFolders(results)
            }
            if growthLoadingPeriod == period {
                growthLoadingPeriod = nil
            }
        }
    }

    /// Initial load — async, for .task on first appearance.
    func loadGrowthData() async {
        ensureGrowthCacheFreshForCurrentDataVersion()
        guard growthFolders == nil else { return }
        let period = growthPeriod
        growthLoadingPeriod = period
        let results = await loadGrowthPeriod(period, forceRefresh: false)
        if growthPeriod == period {
            growthFolders = visibleGrowthFolders(results)
        }
        if growthLoadingPeriod == period {
            growthLoadingPeriod = nil
        }
    }

    /// Reload growth data in-place without clearing first (prevents blank frame flicker).
    /// Only refreshes the current period — other cached periods stay until next switch
    /// (minimal staleness, avoids wiping cache on every FSEvents batch).
    /// Full cache clear happens in startScan() when data truly changes.
    func refreshGrowthData() async {
        ensureGrowthCacheFreshForCurrentDataVersion()
        let period = growthPeriod
        growthLoadingPeriod = period
        let results = await loadGrowthPeriod(period, forceRefresh: true)
        if growthPeriod == period {
            growthFolders = visibleGrowthFolders(results)
        }
        if growthLoadingPeriod == period {
            growthLoadingPeriod = nil
        }
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
        } catch {
            #if DEBUG
            print("[AppState] loadSmartCleanup error: \(error)")
            #endif
        }
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
        } catch {
            #if DEBUG
            print("[AppState] runSmartCleanup error: \(error)")
            #endif
        }

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
            try? await fileRepository.updateSessionStats(id: sessionId)
            self.lastScanSession = try? fileRepository.latestCompletedScanSession()
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
            try? await fileRepository.updateSessionStats(id: sessionId)
            self.lastScanSession = try? fileRepository.latestCompletedScanSession()
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
        // growthFolders is NOT cleared here for the same reason — refreshGrowthData()
        // replaces data atomically. Cleared explicitly in startScan() for new scans.
        duplicateGroups = nil
        staleFiles = nil
        detectedCaches = nil
        cleanupRecommendations = nil
        cleanupSummary = nil
    }

    /// Reload viz data in-place without clearing first (prevents blank frame flicker)
    func refreshVisualizationData() async {
        do {
            if let currentPath = vizCurrentPath, shouldIncludePath(currentPath) {
                vizChildNodes = visibleFileNodes(try fileRepository.childrenWithSizesConcurrent(ofPath: currentPath))
            } else if let root = try fileRepository.rootNodeConcurrent() {
                vizCurrentPath = root.path
                vizChildNodes = visibleFileNodes(try fileRepository.childrenWithSizesConcurrent(ofPath: root.path))
                if !shouldIncludePath(vizCurrentPath ?? root.path) {
                    vizCurrentPath = root.path
                    vizBreadcrumbs = []
                }
            }
        } catch {}
    }

    private func loadGrowthPeriod(_ period: GrowthPeriod, forceRefresh: Bool) async -> [FolderGrowth] {
        ensureGrowthCacheFreshForCurrentDataVersion()
        if !forceRefresh {
            if let cached = growthCache[period] {
                return cached
            }
            if let sessionId = lastScanSession?.id,
               let persisted = try? await fileRepository.cachedGrowthFolders(sessionId: sessionId, period: period) {
                growthCache[period] = persisted
                return persisted
            }
        }

        let cutoff = period.cutoffDate.timeIntervalSince1970
        let excludePrefix = hideExternalDrives ? "/Volumes/" : nil
        let results = (try? await fileRepository.recentlyGrowingFolders(createdAfter: cutoff, excludePrefix: excludePrefix)) ?? []
        growthCache[period] = results
        if let sessionId = lastScanSession?.id {
            try? await fileRepository.upsertGrowthCache(sessionId: sessionId, period: period, folders: results)
        }
        return results
    }

    private func scheduleGrowthWarmup() {
        guard lastScanSession?.id != nil else { return }

        ensureGrowthCacheFreshForCurrentDataVersion()
        growthPrefetchTask?.cancel()
        growthPrefetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            let selectedPeriod = self.growthPeriod
            let selectedResults = await self.loadGrowthPeriod(selectedPeriod, forceRefresh: true)
            if self.growthPeriod == selectedPeriod && self.growthFolders == nil {
                self.growthFolders = self.visibleGrowthFolders(selectedResults)
            }

            for period in GrowthPeriod.allCases where period != selectedPeriod {
                if Task.isCancelled { return }
                _ = await self.loadGrowthPeriod(period, forceRefresh: true)
            }
        }
    }

    private func scheduleCacheWarmup() {
        guard lastScanSession?.id != nil else { return }
        guard detectedCaches == nil else { return }

        cachePrefetchTask?.cancel()
        cachePrefetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.loadCacheData()
        }
    }

    private func loadLastSession() {
        // Synchronous — nonisolated reads bypass actor, no Task needed
        if let completed = try? fileRepository.latestCompletedScanSession() {
            self.lastScanSession = completed
        } else {
            self.lastScanSession = try? fileRepository.latestScanSession()
        }
        if let session = lastScanSession {
            self.scanRootPath = URL(fileURLWithPath: session.rootPath)
            if session.completedAt != nil {
                self.scanState = .completed
                startMonitoring(path: session.rootPath)
            }
        }
    }

    private func refreshVisibilityFilteredData() async {
        do {
            if let root = try fileRepository.rootNodeConcurrent() {
                let top = visibleFileNodes(try fileRepository.childrenWithSizesConcurrent(ofPath: root.path))
                    .filter { $0.isDirectory }
                    .prefix(10)
                    .map { $0 }
                overviewTopFolders = top
            }
        } catch {}

        await refreshVisualizationData()

        // Growth cache stores SQL-filtered results — must re-query with new excludePrefix
        growthCache = [:]
        await refreshGrowthData()
    }

    private func ensureGrowthCacheFreshForCurrentDataVersion() {
        if growthCacheDataVersion != dataVersion {
            growthCache = [:]
            growthCacheDataVersion = dataVersion
        }
    }

    func shouldIncludePath(_ path: String) -> Bool {
        guard hideExternalDrives else { return true }
        if path == "/Volumes" { return false }
        return !path.hasPrefix("/Volumes/")
    }

    private func visibleFileNodes(_ nodes: [FileNode]) -> [FileNode] {
        nodes.filter { shouldIncludePath($0.path) }
    }

    private func visibleGrowthFolders(_ folders: [FolderGrowth]) -> [FolderGrowth] {
        folders.filter { shouldIncludePath($0.folderPath) }
    }
}
