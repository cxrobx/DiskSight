import Foundation
import Combine
import OSLog

final class FSEventsMonitor: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.disksight.app", category: "FSEventsMonitor")
    private var stream: FSEventStreamRef?
    private let repository: FileRepository
    private let sessionId: Int64?
    private let debounceInterval: TimeInterval
    private var pendingEventFlags: [String: UInt32] = [:]
    private var debounceTimer: Timer?
    private let queue = DispatchQueue(label: "com.disksight.fsevents", qos: .utility)
    private let lock = NSLock()
    private var isRunning = false
    private var monitoredPath: String?

    /// Individual events for UI event log (collected/throttled by subscriber)
    let eventSubject = PassthroughSubject<FSEventInfo, Never>()
    /// Published when MustScanSubDirs is detected — subscribers should trigger a full rescan
    let rescanSubject = PassthroughSubject<Void, Never>()
    /// Fires once after a debounced batch of events has been fully processed in DB.
    /// Sends the count of paths that were processed.
    let batchProcessedSubject = PassthroughSubject<Int, Never>()
    /// Operational warnings/errors that should be surfaced in the app-wide activity log.
    let issueSubject = PassthroughSubject<AppOperationMessage, Never>()

    init(repository: FileRepository, sessionId: Int64?, debounceInterval: TimeInterval = 1.0) {
        self.repository = repository
        self.sessionId = sessionId
        self.debounceInterval = debounceInterval
    }

    deinit {
        stop()
    }

    func start(path: String, sinceEventId: UInt64 = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)) {
        stop()

        monitoredPath = path
        let pathCF = [path as CFString] as CFArray

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        guard let stream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &context,
            pathCF,
            sinceEventId,
            debounceInterval,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        isRunning = true
    }

    func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        isRunning = false
    }

    var currentEventId: UInt64 {
        guard let stream = stream else { return UInt64(kFSEventStreamEventIdSinceNow) }
        return FSEventStreamGetLatestEventId(stream)
    }

    var running: Bool { isRunning }

    // MARK: - Event Processing

    fileprivate func handleEvents(paths: [String], flags: [UInt32], ids: [UInt64]) {
        var filteredPaths: [String] = []
        var filteredFlags: [UInt32] = []
        var filteredIDs: [UInt64] = []

        for index in paths.indices {
            let path = paths[index]
            if repository.isManagedStoragePath(path) {
                continue
            }
            if let monitoredPath, IndexedPathRules.shouldExcludeDuringRootScan(path: path, scanRootPath: monitoredPath) {
                continue
            }
            filteredPaths.append(path)
            filteredFlags.append(flags[index])
            filteredIDs.append(ids[index])
        }

        guard !filteredPaths.isEmpty else { return }

        // Check for MustScanSubDirs — macOS can't guarantee individual events,
        // so we need to trigger a full rescan instead of processing individual paths
        for flag in filteredFlags {
            if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                issueSubject.send(
                    AppOperationMessage(
                        level: .warning,
                        title: "Live Monitoring Requested a Rescan",
                        message: "macOS reported that precise file events were unavailable for this batch. DiskSight will run a quick refresh to catch up.",
                        source: "Monitoring"
                    )
                )
                rescanSubject.send()
                return
            }
        }

        lock.lock()
        for (index, path) in filteredPaths.enumerated() {
            pendingEventFlags[path, default: 0] |= filteredFlags[index]
        }
        lock.unlock()

        // Reset debounce timer
        DispatchQueue.main.async { [weak self] in
            self?.debounceTimer?.invalidate()
            self?.debounceTimer = Timer.scheduledTimer(withTimeInterval: self?.debounceInterval ?? 1.0, repeats: false) { [weak self] _ in
                self?.processPendingEvents()
            }
        }

        // Publish events for UI (subscriber collects these in time windows)
        for (i, path) in filteredPaths.enumerated() {
            let flag = filteredFlags[i]
            let eventType: FSEventType
            if flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
                eventType = .deleted
            } else if flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
                eventType = .created
            } else if flag & UInt32(kFSEventStreamEventFlagItemModified) != 0 || flag & UInt32(kFSEventStreamEventFlagItemInodeMetaMod) != 0 {
                eventType = .modified
            } else if flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
                eventType = .renamed
            } else {
                eventType = .modified
            }

            eventSubject.send(FSEventInfo(path: path, type: eventType, eventId: filteredIDs[i]))
        }
    }

    private func processPendingEvents() {
        lock.lock()
        let eventFlagsByPath = pendingEventFlags
        pendingEventFlags.removeAll()
        lock.unlock()

        guard !eventFlagsByPath.isEmpty else { return }

        Task {
            let fm = FileManager.default
            var upsertNodes: [FileNode] = []
            var deletePaths: [String] = []
            var recursiveDeletePaths: [String] = []
            var directorySyncRoots = Set<String>()
            var requiresRescan = false

            let resourceKeys: Set<URLResourceKey> = [
                .fileSizeKey, .isDirectoryKey, .isRegularFileKey,
                .contentModificationDateKey, .contentAccessDateKey,
                .creationDateKey, .typeIdentifierKey, .isSymbolicLinkKey
            ]

            // Classify paths into upserts vs deletes. Directory rename events are
            // escalated to quickSync because their descendants inherit new paths.
            for (path, flags) in eventFlagsByPath {
                let isDirectoryEvent = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
                let isRenameEvent = flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0

                if fm.fileExists(atPath: path) {
                    let url = URL(fileURLWithPath: path)
                    guard let values = try? url.resourceValues(forKeys: resourceKeys) else { continue }
                    if values.isSymbolicLink == true { continue }

                    let isDirectory = values.isDirectory ?? false
                    if !isDirectory && values.isRegularFile != true { continue }

                    if isRenameEvent && isDirectory {
                        requiresRescan = true
                        continue
                    }

                    if isDirectory {
                        directorySyncRoots.insert(path)
                        continue
                    }

                    upsertNodes.append(FileNode(
                        path: path,
                        name: url.lastPathComponent,
                        parentPath: path == "/" ? nil : url.deletingLastPathComponent().path,
                        size: Int64(values.fileSize ?? 0),
                        isDirectory: isDirectory,
                        modifiedAt: values.contentModificationDate?.timeIntervalSince1970,
                        accessedAt: values.contentAccessDate?.timeIntervalSince1970,
                        createdAt: values.creationDate?.timeIntervalSince1970,
                        fileType: values.typeIdentifier,
                        scanSessionId: sessionId
                    ))
                } else {
                    if isDirectoryEvent {
                        recursiveDeletePaths.append(path)
                        if isRenameEvent {
                            requiresRescan = true
                        }
                    } else {
                        deletePaths.append(path)
                    }
                }
            }

            if requiresRescan {
                rescanSubject.send()
                return
            }

            do {
                // Batch DB operations (single DELETE query per 500 instead of N individual calls)
                if !recursiveDeletePaths.isEmpty {
                    try await repository.deleteFilesRecursive(paths: recursiveDeletePaths)
                }
                if !deletePaths.isEmpty {
                    try await repository.deleteFiles(paths: deletePaths)
                }
                if !upsertNodes.isEmpty {
                    try await repository.insertFilesBatch(upsertNodes)
                }

                if let sessionId {
                    let scanner = FileScanner(repository: repository)
                    for rootPath in minimalDirectoryRoots(from: directorySyncRoots) {
                        await scanner.syncSubtree(rootURL: URL(fileURLWithPath: rootPath), sessionId: sessionId)
                        if let directoryNode = refreshedDirectoryNode(atPath: rootPath, resourceKeys: resourceKeys) {
                            try await repository.insertFilesBatch([directoryNode])
                        }
                    }
                }
            } catch {
                logger.error("Failed to apply FSEvents batch: \(error.localizedDescription, privacy: .public)")
                issueSubject.send(
                    AppOperationMessage(
                        level: .error,
                        title: "Live Monitoring Update Failed",
                        message: "DiskSight could not apply a filesystem event batch. Use Refresh Metrics to resync. \(error.localizedDescription)",
                        source: "Monitoring"
                    )
                )
                return
            }

            // Recalculate ancestor directory sizes for all affected paths
            let affectedPaths = Set(eventFlagsByPath.keys).union(directorySyncRoots)
            do {
                try await repository.updateAncestorSizes(forPaths: affectedPaths)
                try await repository.refreshRootDirectorySize()
            } catch {
                logger.error("Failed to refresh directory sizes after FSEvents batch: \(error.localizedDescription, privacy: .public)")
                issueSubject.send(
                    AppOperationMessage(
                        level: .warning,
                        title: "Live Monitoring Needs a Refresh",
                        message: "DiskSight applied live filesystem changes but could not fully recompute directory sizes. Use Refresh Metrics to resync. \(error.localizedDescription)",
                        source: "Monitoring"
                    )
                )
            }

            // Signal batch complete — AppState subscribes to this for cache invalidation
            batchProcessedSubject.send(eventFlagsByPath.count)
        }
    }

    private func minimalDirectoryRoots(from paths: Set<String>) -> [String] {
        let sorted = paths.sorted {
            if $0.count == $1.count {
                return $0 < $1
            }
            return $0.count < $1.count
        }

        var roots: [String] = []
        for path in sorted {
            let covered = roots.contains { root in
                path == root || root == "/" || path.hasPrefix(root + "/")
            }
            if !covered {
                roots.append(path)
            }
        }
        return roots
    }

    private func refreshedDirectoryNode(atPath path: String, resourceKeys: Set<URLResourceKey>) -> FileNode? {
        guard !repository.isManagedStoragePath(path) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return nil }
        guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }

        let totalSize = (try? repository.childrenWithSizesConcurrent(ofPath: path))?.reduce(Int64(0)) { $0 + $1.size } ?? 0
        return FileNode(
            path: path,
            name: url.lastPathComponent,
            parentPath: path == "/" ? nil : url.deletingLastPathComponent().path,
            size: totalSize,
            isDirectory: true,
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970,
            accessedAt: values.contentAccessDate?.timeIntervalSince1970,
            createdAt: values.creationDate?.timeIntervalSince1970,
            fileType: values.typeIdentifier,
            scanSessionId: sessionId
        )
    }
}

// MARK: - C Callback

private func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let monitor = Unmanaged<FSEventsMonitor>.fromOpaque(info).takeUnretainedValue()

    let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    var paths: [String] = []
    var flags: [UInt32] = []
    var ids: [UInt64] = []

    for i in 0..<numEvents {
        if let cfPath = CFArrayGetValueAtIndex(cfPaths, i) {
            let path = Unmanaged<CFString>.fromOpaque(cfPath).takeUnretainedValue() as String
            paths.append(path)
            flags.append(eventFlags[i])
            ids.append(eventIds[i])
        }
    }

    monitor.handleEvents(paths: paths, flags: flags, ids: ids)
}

// MARK: - Event Types

enum FSEventType {
    case created
    case modified
    case deleted
    case renamed
}

struct FSEventInfo {
    let path: String
    let type: FSEventType
    let eventId: UInt64
}
