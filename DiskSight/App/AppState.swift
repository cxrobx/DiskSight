import SwiftUI
import Combine
import OSLog
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
    var errorMessage: String?
}

struct AppAlertInfo: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

enum AppActivityLevel: String, Sendable {
    case info
    case warning
    case error

    var icon: String {
        switch self {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
}

struct AppOperationMessage: Sendable {
    let level: AppActivityLevel
    let title: String
    let message: String
    let source: String
}

struct AppActivityEntry: Identifiable, Sendable {
    let id = UUID()
    let level: AppActivityLevel
    let title: String
    let message: String
    let source: String
    var timestamp: Date
    var occurrenceCount: Int
}

struct TrashFailure: Sendable {
    let path: String
    let reason: String
}

struct TrashOperationResult: Sendable {
    let requestedCount: Int
    let removedFromDiskCount: Int
    let removedMissingCount: Int
    let deletedPaths: [String]
    let failures: [TrashFailure]

    var deletedCount: Int { removedFromDiskCount + removedMissingCount }
    var hasFailures: Bool { !failures.isEmpty }
}

@MainActor
final class AppState: ObservableObject {
    nonisolated static func isTestEnvironment(_ environment: [String: String]) -> Bool {
        [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCTestSessionIdentifier"
        ].contains { key in
            guard let value = environment[key] else { return false }
            return !value.isEmpty
        }
    }

    static let isRunningTests = isTestEnvironment(ProcessInfo.processInfo.environment)

    private let logger = Logger(subsystem: "com.disksight.app", category: "AppState")
    private let maxActivityLogEntries = 200

    nonisolated static func syncCompletedSuccessfully(taskIsCancelled: Bool, lastProgress: ScanProgress?) -> Bool {
        guard !taskIsCancelled else { return false }
        return lastProgress?.completed ?? false
    }

    nonisolated static func storedStaleThreshold() -> StaleThreshold {
        guard let rawValue = UserDefaults.standard.string(forKey: "staleThreshold"),
              let threshold = StaleThreshold(rawValue: rawValue) else {
            return .oneYear
        }
        return threshold
    }

    nonisolated static func growthFolderExists(at path: String) -> Bool {
        let normalizedPath = IndexedPathRules.normalizedPath(path)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    nonisolated static func shouldDisplayGrowthFolder(
        at path: String,
        exists: (String) -> Bool = { AppState.growthFolderExists(at: $0) }
    ) -> Bool {
        let normalizedPath = IndexedPathRules.normalizedPath(path)
        guard !IndexedPathRules.isPseudoFilesystemPath(normalizedPath) else { return false }
        return exists(normalizedPath)
    }

    nonisolated static func sanitizeGrowthFolders(
        _ folders: [FolderGrowth],
        exists: (String) -> Bool = { AppState.growthFolderExists(at: $0) }
    ) -> [FolderGrowth] {
        folders.filter { shouldDisplayGrowthFolder(at: $0.folderPath, exists: exists) }
    }

    private enum SyncTrigger {
        case manualRefresh
        case monitorReplayGap
        case journalRecovery

        var source: String { "Sync" }

        var failureTitle: String {
            switch self {
            case .manualRefresh:
                return "Refresh Failed"
            case .monitorReplayGap:
                return "Live Sync Failed"
            case .journalRecovery:
                return "Recovery Sync Failed"
            }
        }

        var shouldAlertOnFailure: Bool {
            self == .manualRefresh
        }
    }

    @Published var selectedSection: SidebarSection = .overview {
        didSet {
            if selectedSection == .growth, growthDisplayedDataVersion != dataVersion {
                scheduleAutoGrowthRefresh()
            } else if selectedSection != .growth {
                cancelAutoGrowthRefresh()
            }
        }
    }
    @Published var scanState: ScanState = .idle
    @Published var scanRootPath: URL?
    @Published var lastScanSession: ScanSession?
    @Published var hasFullDiskAccess: Bool = false
    @Published var isMonitoring: Bool = false
    @Published var recentEvents: [FSEventInfo] = []
    @Published var isExportingCSV: Bool = false
    @Published var csvExportDone: Bool = false
    @Published var isSyncing: Bool = false
    @Published var activeAlert: AppAlertInfo?
    @Published var activityLog: [AppActivityEntry] = []
    @Published var unreadActivityCount: Int = 0
    @Published var showActivityLog: Bool = false {
        didSet {
            if showActivityLog {
                unreadActivityCount = 0
            }
        }
    }
    @Published var monitoringEnabled: Bool = UserDefaults.standard.object(forKey: "monitoringEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(monitoringEnabled, forKey: "monitoringEnabled")
            handleMonitoringPreferenceChange()
        }
    }

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
    @Published var staleThreshold: StaleThreshold = AppState.storedStaleThreshold() {
        didSet {
            UserDefaults.standard.set(staleThreshold.rawValue, forKey: "staleThreshold")
        }
    }

    // Cache
    @Published var detectedCaches: [DetectedCache]?

    // Growth
    @Published var growthFolders: [FolderGrowth]?
    @Published var growthPeriod: GrowthPeriod = .thirtyDays
    @Published var growthLoadingPeriod: GrowthPeriod?
    private var growthCache: [GrowthPeriod: [FolderGrowth]] = [:]
    private var growthCacheDataVersion: Int = -1
    private var growthDisplayedDataVersion: Int = -1

    // Smart Cleanup
    @Published var cleanupRecommendations: [CleanupRecommendation]?
    @Published var cleanupSummary: CleanupSummary?
    @Published var cleanupProgress: ClassificationProgress?
    @Published var isAnalyzingCleanup: Bool = false
    var cleanupTask: Task<Void, Never>?
    private var cleanupDataVersion: Int?
    @Published var cleanupAnalyzedAt: Date?
    var isCleanupStale: Bool {
        cleanupRecommendations != nil && cleanupDataVersion != dataVersion
    }
    @Published var cleanupLLMProvider: CleanupLLMProvider = UserDefaults.standard.string(forKey: "cleanupLLMProvider")
        .flatMap(CleanupLLMProvider.init(rawValue:)) ?? .ollama {
        didSet {
            UserDefaults.standard.set(cleanupLLMProvider.rawValue, forKey: "cleanupLLMProvider")
        }
    }
    @Published var isOllamaAvailable: Bool = false
    @Published var isClaudeAvailable: Bool = false
    @Published var claudeVersion: String?
    @Published var ollamaModels: [String] = []
    @Published var ollamaBaseURL: String = UserDefaults.standard.string(forKey: "ollamaURL") ?? "http://localhost:11434" {
        didSet {
            UserDefaults.standard.set(ollamaBaseURL, forKey: "ollamaURL")
        }
    }
    @Published var selectedOllamaModel: String = UserDefaults.standard.string(forKey: "ollamaModel") ?? "" {
        didSet {
            UserDefaults.standard.set(selectedOllamaModel, forKey: "ollamaModel")
        }
    }
    @Published var selectedClaudeModel: String = UserDefaults.standard.string(forKey: "claudeModel") ?? "claude-sonnet-4-6" {
        didSet {
            UserDefaults.standard.set(selectedClaudeModel, forKey: "claudeModel")
        }
    }

    private var scanTask: Task<Void, Never>?
    private var incrementalSyncTask: Task<Void, Never>?
    private var cachePrefetchTask: Task<Void, Never>?
    private var growthPrefetchTask: Task<Void, Never>?
    private var growthAutoRefreshTask: Task<Void, Never>?
    private var growthRefreshQueued = false
    private let database: Database
    let fileRepository: FileRepository
    private var storageFailureActive = false
    private var fsMonitor: FSEventsMonitor?
    private var eventCancellable: AnyCancellable?
    private var batchCancellable: AnyCancellable?
    private var rescanCancellable: AnyCancellable?
    private var monitorIssueCancellable: AnyCancellable?
    private var terminationObserver: Any?

    init() {
        self.database = Database.shared
        self.fileRepository = FileRepository(database: database)

        if !Self.isRunningTests {
            checkFullDiskAccess()
            loadLastSession()
            scheduleCacheWarmup()
            scheduleGrowthWarmup()
        }

        // Save event ID synchronously on app quit — can't await in notification handlers
        if !Self.isRunningTests {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.saveEventIdSync()
            }
        }

        if let startupIssue = database.startupIssue {
            presentAlert(
                title: startupIssue.title,
                message: startupIssue.message,
                level: .warning,
                source: "Storage"
            )
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isSelectedLLMAvailable: Bool {
        switch cleanupLLMProvider {
        case .ollama:
            return isOllamaAvailable
        case .claudeHeadless:
            return isClaudeAvailable
        }
    }

    var selectedLLMModelName: String {
        switch cleanupLLMProvider {
        case .ollama:
            return selectedOllamaModel
        case .claudeHeadless:
            return selectedClaudeModel
        }
    }

    var selectedLLMStatusDescription: String {
        switch cleanupLLMProvider {
        case .ollama:
            return isOllamaAvailable ? "Ollama available" : "Ollama unavailable"
        case .claudeHeadless:
            if let claudeVersion, !claudeVersion.isEmpty {
                return "Claude CLI available (\(claudeVersion))"
            }
            return isClaudeAvailable ? "Claude CLI available" : "Claude CLI unavailable"
        }
    }

    func checkFullDiskAccess() {
        let testPath = NSHomeDirectory() + "/Library/Mail"
        hasFullDiskAccess = FileManager.default.isReadableFile(atPath: testPath)
    }

    func startScan(at url: URL) {
        guard !storageFailureActive else {
            presentStorageFailureAlertIfNeeded()
            return
        }
        guard !fileRepository.isManagedStoragePath(url.path) else {
            presentAlert(
                title: "Scan Location Unavailable",
                message: "DiskSight can't scan its own Application Support folder. Choose a different location.",
                level: .warning,
                source: "Scan"
            )
            return
        }

        scanTask?.cancel()
        incrementalSyncTask?.cancel()
        cachePrefetchTask?.cancel()
        growthPrefetchTask?.cancel()
        cancelAutoGrowthRefresh()
        stopMonitoring()

        // Reset viz state — full scan means starting fresh
        vizChildNodes = []
        vizCurrentPath = nil
        vizBreadcrumbs = []
        growthFolders = nil
        growthCache = [:]
        growthDisplayedDataVersion = -1

        invalidateCache()
        scanState = .scanning(progress: ScanProgress())

        scanTask = Task {
            do {
                let scanner = FileScanner(repository: fileRepository)
                let session = try await fileRepository.createScanSession(rootPath: url.path)
                guard let sessionId = session.id else {
                    presentAlert(
                        title: "Scan Failed",
                        message: "DiskSight could not create a scan session.",
                        source: "Scan"
                    )
                    self.scanState = .error("Failed to create scan session")
                    return
                }

                var scanFailure: String?
                for await progress in scanner.scan(rootURL: url, sessionId: sessionId) {
                    if let errorMessage = progress.errorMessage {
                        scanFailure = errorMessage
                        break
                    }
                    self.scanState = .scanning(progress: progress)
                }

                if let scanFailure {
                    self.scanState = .error(scanFailure)
                    presentAlert(
                        title: "Scan Failed",
                        message: "DiskSight could not finish scanning the selected folder. \(scanFailure)",
                        source: "Scan"
                    )
                    return
                }

                guard !Task.isCancelled else { return }

                try await fileRepository.completeScanSession(id: sessionId)
                // Clean up files and sessions from previous scans
                try? await fileRepository.deleteFilesFromPreviousSessions(currentSessionId: sessionId)
                try? await fileRepository.deleteOldSessions(keepingId: sessionId)
                try? await fileRepository.compactIfNeeded()
                self.lastScanSession = try fileRepository.latestCompletedScanSession()
                self.scanState = .completed
                self.scheduleCacheWarmup()
                self.scheduleGrowthWarmup()

                // Start monitoring after scan completes
                startMonitoring(path: url.path)
            } catch {
                if !Task.isCancelled {
                    presentAlert(
                        title: "Scan Failed",
                        message: error.localizedDescription,
                        source: "Scan"
                    )
                    self.scanState = .error(error.localizedDescription)
                }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanState = .idle
    }

    var canRefreshMetrics: Bool {
        guard case .completed = scanState else { return false }
        return scanRootPath != nil || lastScanSession != nil
    }

    func refreshMetrics() {
        guard !storageFailureActive else {
            presentStorageFailureAlertIfNeeded()
            return
        }
        guard case .completed = scanState else { return }
        guard !isSyncing else { return }
        guard let path = scanRootPath?.path ?? lastScanSession?.rootPath else { return }

        if monitoringEnabled && !(fsMonitor?.running ?? false) {
            startMonitoring(path: path)
        }

        runIncrementalSync(path: path, trigger: .manualRefresh)
    }

    // MARK: - FSEvents Monitoring

    func startMonitoring(path: String) {
        guard !storageFailureActive else { return }
        stopMonitoring()
        guard monitoringEnabled else { return }

        let monitor = FSEventsMonitor(repository: fileRepository, sessionId: lastScanSession?.id)
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
                self.invalidateCache(preserveDuplicateGroups: true, preserveStaleFiles: true, preserveDetectedCaches: true, preserveCleanup: true)
                self.dataVersion += 1
                Task { await self.refreshVisualizationData() }
                self.scheduleAutoGrowthRefresh()

                // Persist latest event ID for crash recovery
                if let monitor = self.fsMonitor,
                   let session = self.lastScanSession, let sessionId = session.id {
                    let eventId = monitor.currentEventId
                    // Update in-memory session so handleBecameActive uses fresh event ID
                    self.lastScanSession?.lastFseventsId = Int64(eventId)
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.fileRepository.updateEventId(
                                sessionId: sessionId,
                                eventId: Int64(eventId)
                            )
                        } catch {
                            self.recordActivity(
                                level: .warning,
                                title: "Monitoring Position Was Not Saved",
                                message: "DiskSight updated live results, but could not persist the latest event marker. \(error.localizedDescription)",
                                source: "Monitoring"
                            )
                        }
                    }
                }
            }

        monitorIssueCancellable = monitor.issueSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] issue in
                self?.recordActivity(issue)
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
                recordActivity(
                    level: .warning,
                    title: "Recovering Live Monitoring",
                    message: "The saved filesystem event position is more than seven days old, so DiskSight will run a recovery refresh.",
                    source: "Monitoring"
                )
                // Full walk catches the gap since the last session (>7 days stale)
                runIncrementalSync(path: path, fullWalk: true, trigger: .journalRecovery)
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
        monitorIssueCancellable = nil
        isMonitoring = false
    }

    private func handleMonitoringPreferenceChange() {
        guard case .completed = scanState else { return }

        if monitoringEnabled, let rootPath = scanRootPath?.path ?? lastScanSession?.rootPath {
            startMonitoring(path: rootPath)
        } else {
            stopMonitoring()
        }
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
        guard !isSyncing else { return }
        // Skip if session is very fresh — FSEvents will catch any changes going forward.
        // MustScanSubDirs during initial replay doesn't mean data is stale; it just means
        // the kernel can't guarantee individual event paths.
        if let completedAt = lastScanSession?.completedAt {
            let fiveMinutesAgo = Date().timeIntervalSince1970 - 300
            if completedAt > fiveMinutesAgo { return }
        }
        runIncrementalSync(path: rootPath.path, trigger: .monitorReplayGap)
    }

    /// Background incremental sync — walks the filesystem and upserts only new/modified
    /// files, deletes removed ones. Does NOT change scanState, so the UI stays usable
    /// with existing viz data during the sync.
    /// - Parameter fullWalk: When true, uses iterative DFS without mtime pruning (for stale >7 day gaps).
    ///   When false (default), uses fast quickSync with mtime pruning.
    private func runIncrementalSync(path: String, fullWalk: Bool = false, trigger: SyncTrigger) {
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
                if !Task.isCancelled {
                    let failureMessage = lastProgress?.errorMessage
                        ?? "DiskSight stopped before the refresh completed. Use Refresh Metrics to resync."
                    if trigger.shouldAlertOnFailure {
                        self.presentAlert(
                            title: trigger.failureTitle,
                            message: failureMessage,
                            source: trigger.source
                        )
                    } else {
                        self.recordActivity(
                            level: .error,
                            title: trigger.failureTitle,
                            message: failureMessage,
                            source: trigger.source
                        )
                    }
                }
                self.isSyncing = false
                return
            }

            do {
                try await fileRepository.updateSessionStats(id: sessionId)
            } catch {
                let message = "DiskSight refreshed files, but could not update session stats. \(error.localizedDescription)"
                if trigger.shouldAlertOnFailure {
                    self.presentAlert(
                        title: "Refresh Incomplete",
                        message: message,
                        level: .warning,
                        source: trigger.source
                    )
                } else {
                    self.recordActivity(
                        level: .warning,
                        title: "Refresh Incomplete",
                        message: message,
                        source: trigger.source
                    )
                }
                self.isSyncing = false
                return
            }

            do {
                self.lastScanSession = try fileRepository.latestCompletedScanSession()
            } catch {
                let message = "DiskSight refreshed files, but could not reload the latest session state. \(error.localizedDescription)"
                if trigger.shouldAlertOnFailure {
                    self.presentAlert(
                        title: "Refresh Incomplete",
                        message: message,
                        level: .warning,
                        source: trigger.source
                    )
                } else {
                    self.recordActivity(
                        level: .warning,
                        title: "Refresh Incomplete",
                        message: message,
                        source: trigger.source
                    )
                }
                self.isSyncing = false
                return
            }

            self.invalidateCache(preserveDuplicateGroups: true, preserveStaleFiles: true, preserveDetectedCaches: true, preserveCleanup: true)
            self.dataVersion += 1
            await self.refreshVisualizationData()
            self.scheduleAutoGrowthRefresh()
            self.isSyncing = false
        }
    }

    /// Called when the app returns to the foreground. Restarts monitoring if
    /// the FSEvents stream died. Cache invalidation happens naturally via
    /// the FSEvents sink when real changes are detected.
    func handleBecameActive() {
        guard !Self.isRunningTests else { return }
        guard !storageFailureActive else { return }

        // Only re-query if we have no session — avoids a redundant DB hit on every cmd-tab
        if lastScanSession == nil {
            if let session = try? fileRepository.latestCompletedScanSession() {
                self.lastScanSession = session
                self.scanRootPath = URL(fileURLWithPath: session.rootPath)
                scheduleCacheWarmup()
                scheduleGrowthWarmup()
            }
        }
        if monitoringEnabled, let rootPath = lastScanSession?.rootPath, !(fsMonitor?.running ?? false) {
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
            defer { isExportingCSV = false }
            do {
                try await CSVExporter.stream(from: fileRepository, sessionId: sessionId, to: url)
                csvExportDone = true
                recordActivity(
                    level: .info,
                    title: "Export Complete",
                    message: "Saved a CSV export to \(url.path).",
                    source: "Export",
                    incrementUnread: false
                )
                // Clear success indicator after 3 seconds
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self.csvExportDone = false
                }
            } catch {
                logger.error("CSV export failed: \(error.localizedDescription, privacy: .public)")
                presentAlert(
                    title: "Export Failed",
                    message: "DiskSight could not write the CSV export. \(error.localizedDescription)",
                    source: "Export"
                )
            }
        }
    }

    // MARK: - Cached Data Loading

    func loadOverviewData() async {
        guard overviewFileCount == nil else { return }
        do {
            if let session = lastScanSession, let sessionId = session.id {
                overviewFileCount = try fileRepository.fileCount(sessionId: sessionId)
                overviewTotalSize = try fileRepository.totalSize(sessionId: sessionId)
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
            recordActivity(
                level: .warning,
                title: "Could Not Load Overview Data",
                message: error.localizedDescription,
                source: "Overview"
            )
            #if DEBUG
            print("[AppState] loadOverviewData error: \(error)")
            #endif
        }
    }

    /// Reload overview data in-place without clearing first (prevents blank frame flicker)
    func refreshOverviewData() async {
        do {
            if let session = lastScanSession, let sessionId = session.id {
                overviewFileCount = try fileRepository.fileCount(sessionId: sessionId)
                overviewTotalSize = try fileRepository.totalSize(sessionId: sessionId)
                if let root = try fileRepository.rootNodeConcurrent() {
                    overviewTopFolders = visibleFileNodes(try fileRepository.childrenWithSizesConcurrent(ofPath: root.path))
                        .filter { $0.isDirectory }
                        .prefix(10)
                        .map { $0 }
                }
            }
        } catch {
            #if DEBUG
            print("[AppState] refreshOverviewData error: \(error)")
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
            recordActivity(
                level: .warning,
                title: "Could Not Load Visualization",
                message: error.localizedDescription,
                source: "Visualization"
            )
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
            recordActivity(
                level: .warning,
                title: "Could Not Open Folder View",
                message: error.localizedDescription,
                source: "Visualization"
            )
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
            recordActivity(
                level: .warning,
                title: "Could Not Open Folder View",
                message: error.localizedDescription,
                source: "Visualization"
            )
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
            recordActivity(
                level: .warning,
                title: "Could Not Open Folder View",
                message: error.localizedDescription,
                source: "Visualization"
            )
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
        // Update threshold but keep old results visible until new data arrives
        staleThreshold = threshold
        let finder = StaleFinder(repository: fileRepository)
        do {
            staleFiles = try await finder.findStaleFiles(threshold: threshold)
        } catch {
            staleFiles = []
            recordActivity(
                level: .warning,
                title: "Could Not Load Stale Files",
                message: error.localizedDescription,
                source: "Stale Files"
            )
        }
    }

    func loadCacheData() async {
        guard detectedCaches == nil else { return }
        let detector = CacheDetector(repository: fileRepository)
        do {
            detectedCaches = try await detector.detectCaches()
        } catch {
            detectedCaches = []
            recordActivity(
                level: .warning,
                title: "Could Not Load Cache Data",
                message: error.localizedDescription,
                source: "Cache"
            )
        }
    }

    /// Synchronous period switch — instant for in-memory or DB cache hits, async SQL as last resort.
    func switchGrowthPeriod(to period: GrowthPeriod) {
        let invalidated = ensureGrowthCacheFreshForCurrentDataVersion()
        let requiresLiveRefresh = invalidated || growthDisplayedDataVersion != dataVersion
        growthPeriod = period

        // 1. In-memory cache hit → instant
        if !requiresLiveRefresh, let cached = growthCache[period] {
            growthFolders = visibleGrowthFolders(cached)
            growthDisplayedDataVersion = dataVersion
            growthLoadingPeriod = nil
            return
        }

        // 2. Show loading, then load cached/fresh data in background.
        growthLoadingPeriod = period
        growthFolders = nil
        Task {
            if let cached = await cachedGrowthPeriod(period) {
                if growthPeriod == period {
                    growthFolders = visibleGrowthFolders(cached)
                    if !requiresLiveRefresh {
                        growthDisplayedDataVersion = dataVersion
                    }
                }
                if !requiresLiveRefresh, growthLoadingPeriod == period {
                    growthLoadingPeriod = nil
                    return
                }
            }

            let results = await loadGrowthPeriod(period, forceRefresh: requiresLiveRefresh)
            if growthPeriod == period {
                growthFolders = visibleGrowthFolders(results)
                growthDisplayedDataVersion = dataVersion
            }
            if growthLoadingPeriod == period {
                growthLoadingPeriod = nil
            }
        }
    }

    /// Initial load — for .task on first appearance. Tries caches before expensive SQL.
    func loadGrowthData() async {
        let invalidated = ensureGrowthCacheFreshForCurrentDataVersion()
        let period = growthPeriod
        let requiresLiveRefresh = invalidated || growthDisplayedDataVersion != dataVersion

        guard growthFolders == nil || requiresLiveRefresh else { return }

        if let cached = await cachedGrowthPeriod(period) {
            growthFolders = visibleGrowthFolders(cached)
            if !requiresLiveRefresh {
                growthDisplayedDataVersion = dataVersion
                growthLoadingPeriod = nil
                return
            }
        }

        growthLoadingPeriod = period
        let results = await loadGrowthPeriod(period, forceRefresh: requiresLiveRefresh)
        if growthPeriod == period {
            growthFolders = visibleGrowthFolders(results)
            growthDisplayedDataVersion = dataVersion
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
            growthDisplayedDataVersion = dataVersion
        }
        if growthLoadingPeriod == period {
            growthLoadingPeriod = nil
        }
    }

    // MARK: - Smart Cleanup

    func loadSmartCleanup() async {
        // No-op — results are computed on demand (analysis takes seconds)
        // and kept in memory. No DB caching needed.
    }

    func runSmartCleanup(useLLM: Bool = false) async {
        guard let session = lastScanSession, let sessionId = session.id else { return }
        isAnalyzingCleanup = true
        cleanupRecommendations = nil
        cleanupSummary = nil
        cleanupProgress = ClassificationProgress(processed: 0, total: 0, currentFile: "Loading files...")

        do {
            var llmService: CleanupLLMServing?
            var llmModel: String?
            if useLLM {
                await refreshSelectedLLMStatus()

                switch cleanupLLMProvider {
                case .ollama:
                    let model = selectedOllamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isOllamaAvailable && !model.isEmpty {
                        llmService = OllamaClient(baseURL: ollamaBaseURL)
                        llmModel = model
                    } else {
                        recordActivity(
                            level: .warning,
                            title: "LLM Enhancement Disabled",
                            message: "Ollama is not available. Smart Cleanup continued with rule-based analysis only.",
                            source: "Smart Cleanup"
                        )
                    }
                case .claudeHeadless:
                    let model = selectedClaudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isClaudeAvailable && !model.isEmpty {
                        llmService = ClaudeCLIClient()
                        llmModel = model
                    } else {
                        let message = isClaudeAvailable
                            ? "No Claude model is configured. Smart Cleanup continued with rule-based analysis only."
                            : "Claude CLI is not available. Smart Cleanup continued with rule-based analysis only."
                        recordActivity(
                            level: .warning,
                            title: "LLM Enhancement Disabled",
                            message: message,
                            source: "Smart Cleanup"
                        )
                    }
                }
            }

            let service = SmartCleanupService(
                classifier: FileClassifier(),
                repository: fileRepository,
                llmService: llmService
            )

            var allRecs: [CleanupRecommendation] = []
            let stream = await service.analyze(sessionId: sessionId, llmModel: llmModel)
            for await (progress, recs) in stream {
                guard !Task.isCancelled else { break }
                cleanupProgress = progress
                if !recs.isEmpty {
                    allRecs.append(contentsOf: recs)
                }
            }

            // Summary uses all results; UI shows top 500 by size to avoid SwiftUI crash
            cleanupSummary = CleanupSummary.fromRecommendations(allRecs)
            let displayRecs = Array(allRecs
                .filter { $0.confidence != .keep }
                .sorted { $0.fileSize > $1.fileSize }
                .prefix(500))
            cleanupRecommendations = displayRecs
            cleanupDataVersion = dataVersion
            cleanupAnalyzedAt = Date()

            // DB persist skipped — analysis completes in seconds so caching
            // across launches isn't needed, and 33k inserts cause SQLite writer
            // contention with FSEvents that beachballs the app.
        } catch {
            logger.error("Smart cleanup failed: \(error.localizedDescription, privacy: .public)")
            presentAlert(
                title: "Smart Cleanup Failed",
                message: "DiskSight could not finish the cleanup analysis. \(error.localizedDescription)",
                source: "Smart Cleanup"
            )
            #if DEBUG
            print("[AppState] runSmartCleanup error: \(error)")
            #endif
        }

        isAnalyzingCleanup = false
        cleanupProgress = nil
        cleanupTask = nil
    }

    func cancelSmartCleanup() {
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    func checkLLMStatus() async {
        async let ollamaStatus = OllamaClient(baseURL: ollamaBaseURL).checkAvailability()
        async let claudeStatus = ClaudeCLIClient().checkAvailability()
        applyOllamaStatus(await ollamaStatus)
        applyClaudeStatus(await claudeStatus)
    }

    func checkOllamaStatus() async {
        await refreshOllamaStatus()
    }

    private func refreshSelectedLLMStatus() async {
        switch cleanupLLMProvider {
        case .ollama:
            await refreshOllamaStatus()
        case .claudeHeadless:
            await refreshClaudeStatus()
        }
    }

    private func refreshOllamaStatus() async {
        let status = await OllamaClient(baseURL: ollamaBaseURL).checkAvailability()
        applyOllamaStatus(status)
    }

    private func refreshClaudeStatus() async {
        let status = await ClaudeCLIClient().checkAvailability()
        applyClaudeStatus(status)
    }

    private func applyOllamaStatus(_ status: OllamaStatus) {
        switch status {
        case .available(let models):
            isOllamaAvailable = true
            ollamaModels = models
            if !models.contains(selectedOllamaModel), let first = models.first {
                selectedOllamaModel = first
            }
        case .unavailable:
            isOllamaAvailable = false
            ollamaModels = []
        }
    }

    private func applyClaudeStatus(_ status: ClaudeCLIStatus) {
        switch status {
        case .available(let version):
            isClaudeAvailable = true
            claudeVersion = version
        case .unavailable:
            isClaudeAvailable = false
            claudeVersion = nil
        }
    }

    func trashCleanupFile(at path: String) async {
        let result = await trashIndexedPaths([path], actionName: "processing cleanup selections")
        guard result.deletedCount > 0 else { return }

        // Remove from local recommendations
        cleanupRecommendations?.removeAll { $0.filePath == path }
        await refreshAfterIndexedFileMutation(preserveCleanup: true)
    }

    func trashAllSafeCleanup() async {
        guard let recs = cleanupRecommendations?.filter({ $0.confidence == .safe }) else { return }
        let result = await trashIndexedPaths(recs.map(\.filePath), actionName: "processing cleanup selections")
        guard result.deletedCount > 0 else { return }
        cleanupRecommendations?.removeAll { $0.confidence == .safe }
        await refreshAfterIndexedFileMutation(preserveCleanup: true)
    }

    func presentAlert(
        title: String,
        message: String,
        level: AppActivityLevel = .error,
        source: String = "Operations",
        logToActivity: Bool = true
    ) {
        activeAlert = AppAlertInfo(title: title, message: message)
        if logToActivity {
            recordActivity(level: level, title: title, message: message, source: source)
        }
    }

    func recordActivity(_ operation: AppOperationMessage, incrementUnread: Bool = true) {
        recordActivity(
            level: operation.level,
            title: operation.title,
            message: operation.message,
            source: operation.source,
            incrementUnread: incrementUnread
        )
    }

    func recordActivity(
        level: AppActivityLevel,
        title: String,
        message: String,
        source: String,
        incrementUnread: Bool = true
    ) {
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        if !activityLog.isEmpty,
           activityLog[0].level == level,
           activityLog[0].title == title,
           activityLog[0].message == normalizedMessage,
           activityLog[0].source == source {
            activityLog[0].timestamp = now
            activityLog[0].occurrenceCount += 1
        } else {
            activityLog.insert(
                AppActivityEntry(
                    level: level,
                    title: title,
                    message: normalizedMessage,
                    source: source,
                    timestamp: now,
                    occurrenceCount: 1
                ),
                at: 0
            )
            if activityLog.count > maxActivityLogEntries {
                activityLog.removeLast(activityLog.count - maxActivityLogEntries)
            }
        }

        if incrementUnread && !showActivityLog && level != .info {
            unreadActivityCount += 1
        }

        handlePersistentStorageFailureIfNeeded(message: normalizedMessage)
    }

    func clearActivityLog() {
        activityLog.removeAll()
        unreadActivityCount = 0
    }

    func trashIndexedPaths(_ paths: [String], actionName: String) async -> TrashOperationResult {
        let uniquePaths = Array(NSOrderedSet(array: paths)) as? [String] ?? paths
        guard !uniquePaths.isEmpty else {
            return TrashOperationResult(
                requestedCount: 0,
                removedFromDiskCount: 0,
                removedMissingCount: 0,
                deletedPaths: [],
                failures: []
            )
        }

        var removedFromDiskPaths: [String] = []
        var removedMissingPaths: [String] = []
        var failures: [TrashFailure] = []

        for path in uniquePaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    try await fileRepository.deleteFile(path: path)
                    removedFromDiskPaths.append(path)
                } catch {
                    logger.error("Failed to trash \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    failures.append(TrashFailure(path: path, reason: error.localizedDescription))
                }
            } else {
                do {
                    try await fileRepository.deleteFile(path: path)
                    removedMissingPaths.append(path)
                } catch {
                    logger.error("Failed to remove missing index entry \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    failures.append(TrashFailure(path: path, reason: error.localizedDescription))
                }
            }
        }

        let deletedPaths = removedFromDiskPaths + removedMissingPaths
        if !deletedPaths.isEmpty {
            do {
                try await fileRepository.deleteRecommendations(forFilePaths: deletedPaths)
                try await fileRepository.updateAncestorSizes(forPaths: Set(deletedPaths))
                try await fileRepository.refreshRootDirectorySize()
            } catch {
                logger.error("Failed to refresh sizes after trashing files: \(error.localizedDescription, privacy: .public)")
                presentAlert(
                    title: "Index Refresh Needed",
                    message: "DiskSight moved files to Trash, but could not fully refresh its index. Use Refresh Metrics to resync.",
                    level: .warning,
                    source: "Index"
                )
            }
        }

        if !failures.isEmpty {
            let names = failures
                .prefix(3)
                .map { URL(fileURLWithPath: $0.path).lastPathComponent }
                .joined(separator: ", ")
            let suffix = failures.count > 3 ? " and \(failures.count - 3) more" : ""
            let successMessage: String
            if deletedPaths.isEmpty {
                successMessage = ""
            } else {
                successMessage = "DiskSight removed \(deletedPaths.count) item(s) while \(actionName). "
            }
            presentAlert(
                title: "Some Items Could Not Be Removed",
                message: "\(successMessage)Failed items: \(names)\(suffix).",
                level: .warning,
                source: "Cleanup"
            )
        }

        return TrashOperationResult(
            requestedCount: uniquePaths.count,
            removedFromDiskCount: removedFromDiskPaths.count,
            removedMissingCount: removedMissingPaths.count,
            deletedPaths: deletedPaths,
            failures: failures
        )
    }

    func refreshAfterIndexedFileMutation(
        preserveDuplicateGroups: Bool = false,
        preserveStaleFiles: Bool = false,
        preserveDetectedCaches: Bool = false,
        preserveCleanup: Bool = false
    ) async {
        invalidateCache(
            preserveDuplicateGroups: preserveDuplicateGroups,
            preserveStaleFiles: preserveStaleFiles,
            preserveDetectedCaches: preserveDetectedCaches,
            preserveCleanup: preserveCleanup
        )

        if let session = lastScanSession, let sessionId = session.id {
            do {
                try await fileRepository.updateSessionStats(id: sessionId)
                self.lastScanSession = try fileRepository.latestCompletedScanSession()
                if preserveCleanup {
                    cleanupSummary = try await fileRepository.recommendationSummary(forSession: sessionId)
                }
            } catch {
                logger.error("Failed to refresh session stats after mutation: \(error.localizedDescription, privacy: .public)")
                presentAlert(
                    title: "Index Refresh Needed",
                    message: "DiskSight updated the files but could not refresh session stats. Use Refresh Metrics to resync.",
                    level: .warning,
                    source: "Index"
                )
            }
        }

        dataVersion += 1
        await refreshVisualizationData()
        scheduleAutoGrowthRefresh()
    }

    func invalidateCache(
        preserveDuplicateGroups: Bool = false,
        preserveStaleFiles: Bool = false,
        preserveDetectedCaches: Bool = false,
        preserveCleanup: Bool = false
    ) {
        // overviewFileCount/overviewTotalSize/overviewTopFolders are NOT cleared here —
        // clearing them causes a blank frame (Files: 0, Zero KB) before the reload completes.
        // Instead, refreshOverviewData() replaces the data atomically.
        // vizChildNodes is NOT cleared here — clearing it causes a blank frame
        // because the view shows the empty state before the reload completes.
        // Instead, refreshVisualizationData() replaces the data atomically.
        // vizCurrentPath and vizBreadcrumbs are navigation state, not cached data.
        // growthFolders is NOT cleared here for the same reason — refreshGrowthData()
        // replaces data atomically. Cleared explicitly in startScan() for new scans.
        growthDisplayedDataVersion = -1
        if !preserveDuplicateGroups {
            duplicateGroups = nil
        }
        if !preserveStaleFiles {
            staleFiles = nil
        }
        if !preserveDetectedCaches {
            detectedCaches = nil
        }
        if !preserveCleanup {
            cleanupRecommendations = nil
            cleanupSummary = nil
            cleanupDataVersion = nil
            cleanupAnalyzedAt = nil
        }
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
        } catch {
            recordActivity(
                level: .warning,
                title: "Visualization Refresh Failed",
                message: error.localizedDescription,
                source: "Visualization"
            )
        }
    }

    private func persistedGrowthCache(sessionId: Int64, period: GrowthPeriod) async -> [FolderGrowth]? {
        let repository = fileRepository
        return await Task.detached(priority: .utility) {
            repository.cachedGrowthFoldersConcurrent(sessionId: sessionId, period: period)
        }.value
    }

    private func cachedGrowthPeriod(_ period: GrowthPeriod) async -> [FolderGrowth]? {
        if let cached = growthCache[period] {
            let sanitized = Self.sanitizeGrowthFolders(cached)
            if sanitized.count != cached.count {
                growthCache[period] = sanitized
                if let sessionId = lastScanSession?.id {
                    persistGrowthCache(sanitized, sessionId: sessionId, period: period)
                }
            }
            return sanitized
        }

        if let sessionId = lastScanSession?.id,
           let persisted = await persistedGrowthCache(sessionId: sessionId, period: period) {
            let sanitized = Self.sanitizeGrowthFolders(persisted)
            growthCache[period] = sanitized
            if sanitized.count != persisted.count {
                persistGrowthCache(sanitized, sessionId: sessionId, period: period)
            }
            return sanitized
        }

        return nil
    }

    private func queryGrowthFolders(period: GrowthPeriod) async -> [FolderGrowth] {
        let repository = fileRepository
        let cutoff = period.cutoffDate.timeIntervalSince1970
        let excludePrefix = hideExternalDrives ? "/Volumes/" : nil
        return await Task.detached(priority: .utility) {
            (try? repository.recentlyGrowingFoldersConcurrent(createdAfter: cutoff, excludePrefix: excludePrefix)) ?? []
        }.value
    }

    private func persistGrowthCache(_ folders: [FolderGrowth], sessionId: Int64, period: GrowthPeriod) {
        let repository = fileRepository
        Task.detached(priority: .utility) {
            try? await repository.upsertGrowthCache(sessionId: sessionId, period: period, folders: folders)
        }
    }

    private func loadGrowthPeriod(_ period: GrowthPeriod, forceRefresh: Bool) async -> [FolderGrowth] {
        ensureGrowthCacheFreshForCurrentDataVersion()
        if !forceRefresh {
            if let persisted = await cachedGrowthPeriod(period) {
                return persisted
            }
        }

        let results = Self.sanitizeGrowthFolders(await queryGrowthFolders(period: period))
        growthCache[period] = results
        if let sessionId = lastScanSession?.id {
            persistGrowthCache(results, sessionId: sessionId, period: period)
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
            let selectedResults = await self.loadGrowthPeriod(selectedPeriod, forceRefresh: false)
            if self.growthPeriod == selectedPeriod && self.growthFolders == nil {
                self.growthFolders = self.visibleGrowthFolders(selectedResults)
                self.growthDisplayedDataVersion = self.dataVersion
            }

            for period in GrowthPeriod.allCases where period != selectedPeriod {
                if Task.isCancelled { return }
                _ = await self.loadGrowthPeriod(period, forceRefresh: false)
            }
        }
    }

    private func scheduleAutoGrowthRefresh() {
        guard selectedSection == .growth else {
            growthRefreshQueued = true
            return
        }

        growthRefreshQueued = true
        guard growthAutoRefreshTask == nil else { return }

        growthAutoRefreshTask = Task {
            while growthRefreshQueued {
                growthRefreshQueued = false
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard !Task.isCancelled else { return }
                await refreshGrowthData()
            }
            growthAutoRefreshTask = nil
        }
    }

    private func cancelAutoGrowthRefresh() {
        growthRefreshQueued = false
        growthAutoRefreshTask?.cancel()
        growthAutoRefreshTask = nil
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
                if monitoringEnabled {
                    startMonitoring(path: session.rootPath)
                }
            }
        }

        sanitizeManagedStorageIfNeeded()
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
        } catch {
            recordActivity(
                level: .warning,
                title: "Filtered Refresh Failed",
                message: error.localizedDescription,
                source: "Overview"
            )
        }

        await refreshVisualizationData()

        // Growth cache stores SQL-filtered results — must re-query with new excludePrefix
        growthCache = [:]
        await refreshGrowthData()
    }

    @discardableResult
    private func ensureGrowthCacheFreshForCurrentDataVersion() -> Bool {
        if growthCacheDataVersion != dataVersion {
            growthCache = [:]
            growthCacheDataVersion = dataVersion
            return true
        }
        return false
    }

    func shouldIncludePath(_ path: String) -> Bool {
        if fileRepository.isManagedStoragePath(path) {
            return false
        }
        if IndexedPathRules.isPseudoFilesystemPath(path) {
            return false
        }
        guard hideExternalDrives else { return true }
        if path == "/Volumes" { return false }
        return !path.hasPrefix("/Volumes/")
    }

    private func visibleFileNodes(_ nodes: [FileNode]) -> [FileNode] {
        nodes.filter { shouldIncludePath($0.path) }
    }

    private func visibleGrowthFolders(_ folders: [FolderGrowth]) -> [FolderGrowth] {
        Self.sanitizeGrowthFolders(folders).filter { shouldIncludePath($0.folderPath) }
    }

    private func sanitizeManagedStorageIfNeeded() {
        guard let session = lastScanSession else { return }

        let scanRoot = URL(fileURLWithPath: session.rootPath).standardizedFileURL.path
        let storagePath = fileRepository.managedStorageDirectoryPath
        let sessionCanContainManagedStorage = fileRepository.isManagedStoragePath(scanRoot)
            || scanRoot == "/"
            || storagePath.hasPrefix(scanRoot + "/")
        guard sessionCanContainManagedStorage else { return }

        Task(priority: .utility) { [weak self] in
            guard let self else { return }

            do {
                let deletedCount = try await self.fileRepository.deleteIndexedPaths(inExcludedRoots: [storagePath])
                guard deletedCount > 0 else { return }

                try await self.fileRepository.updateAncestorSizes(forPaths: Set([storagePath]))
                try await self.fileRepository.refreshRootDirectorySize()
                await self.refreshAfterIndexedFileMutation(preserveDuplicateGroups: true, preserveStaleFiles: true, preserveDetectedCaches: true, preserveCleanup: true)
                try? await self.fileRepository.compactIfNeeded()

                self.recordActivity(
                    level: .warning,
                    title: "Removed DiskSight Storage from Results",
                    message: "DiskSight removed its own private database folder from the indexed data and refreshed totals.",
                    source: "Storage",
                    incrementUnread: false
                )
            } catch {
                self.logger.error("Failed to sanitize managed storage paths: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handlePersistentStorageFailureIfNeeded(message: String) {
        guard !storageFailureActive else { return }
        guard Database.isLikelyPersistentStorageFailure(message: message) else { return }

        storageFailureActive = true
        scanTask?.cancel()
        incrementalSyncTask?.cancel()
        isSyncing = false
        isAnalyzingCleanup = false
        cleanupProgress = nil
        stopMonitoring()
        presentStorageFailureAlertIfNeeded()
    }

    private func presentStorageFailureAlertIfNeeded() {
        let storagePath = database.storageDirectoryURL.path
        activeAlert = AppAlertInfo(
            title: "Disk Index Unavailable",
            message: "DiskSight lost access to its local index in \(storagePath). Quit and reopen the app to let DiskSight recover it. If the problem returns, check disk space and folder permissions."
        )
    }
}
