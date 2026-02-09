import Foundation
import Combine

final class FSEventsMonitor: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let repository: FileRepository
    private let debounceInterval: TimeInterval
    private var pendingPaths = Set<String>()
    private var debounceTimer: Timer?
    private let queue = DispatchQueue(label: "com.disksight.fsevents", qos: .utility)
    private let lock = NSLock()
    private var isRunning = false
    private var monitoredPath: String?

    let eventSubject = PassthroughSubject<FSEventInfo, Never>()

    init(repository: FileRepository, debounceInterval: TimeInterval = 2.0) {
        self.repository = repository
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
        lock.lock()
        for path in paths {
            pendingPaths.insert(path)
        }
        lock.unlock()

        // Reset debounce timer
        DispatchQueue.main.async { [weak self] in
            self?.debounceTimer?.invalidate()
            self?.debounceTimer = Timer.scheduledTimer(withTimeInterval: self?.debounceInterval ?? 2.0, repeats: false) { [weak self] _ in
                self?.processPendingEvents()
            }
        }

        // Publish events for UI
        for (i, path) in paths.enumerated() {
            let flag = flags[i]
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

            eventSubject.send(FSEventInfo(path: path, type: eventType, eventId: ids[i]))
        }
    }

    private func processPendingEvents() {
        lock.lock()
        let paths = pendingPaths
        pendingPaths.removeAll()
        lock.unlock()

        guard !paths.isEmpty else { return }

        Task {
            for path in paths {
                await processPath(path)
            }
        }
    }

    private func processPath(_ path: String) async {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default

        if fm.fileExists(atPath: path) {
            // Create or update
            let resourceKeys: Set<URLResourceKey> = [
                .fileSizeKey, .isDirectoryKey,
                .contentModificationDateKey, .contentAccessDateKey,
                .creationDateKey, .typeIdentifierKey
            ]

            guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return }

            let node = FileNode(
                path: path,
                name: url.lastPathComponent,
                parentPath: url.deletingLastPathComponent().path,
                size: Int64(values.fileSize ?? 0),
                isDirectory: values.isDirectory ?? false,
                modifiedAt: values.contentModificationDate?.timeIntervalSince1970,
                accessedAt: values.contentAccessDate?.timeIntervalSince1970,
                createdAt: values.creationDate?.timeIntervalSince1970,
                fileType: values.typeIdentifier
            )

            try? await repository.insertFilesBatch([node])
        } else {
            // Deleted
            try? await repository.deleteFile(path: path)
        }
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
