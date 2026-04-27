import Foundation
import OSLog

struct FileScanner {
    private let logger = Logger(subsystem: "com.disksight.app", category: "FileScanner")
    private let repository: FileRepository
    private let batchSize = 1000

    init(repository: FileRepository) {
        self.repository = repository
    }

    /// Reconcile a changed directory subtree against disk state. This is used by
    /// FSEvents batches when a directory was replaced or rebuilt in place, which
    /// can leave stale descendants behind if we only upsert the directory row.
    func syncSubtree(rootURL: URL, sessionId: Int64) async {
        guard !repository.isManagedStoragePath(rootURL.path) else { return }
        let stream = quickSync(rootURL: rootURL, since: 0, sessionId: sessionId)
        for await _ in stream {}
    }

    private func shouldExcludeExternalVolume(
        url: URL,
        isDirectory: Bool,
        rootURL: URL,
        values: URLResourceValues
    ) -> Bool {
        guard rootURL.path == "/" else { return false }
        guard isDirectory else { return false }
        guard url.path.hasPrefix("/Volumes/") else { return false }
        return values.volumeIsInternal == false
    }

    func quickSync(rootURL: URL, since: Double, sessionId: Int64) -> AsyncStream<ScanProgress> {
        AsyncStream { continuation in
            let producerTask = Task {
                do {
                    var progress = ScanProgress()
                    var upsertBatch: [FileNode] = []
                    var deleteBatch: [String] = []
                    var affectedPaths = Set<String>()
                    var dirCount = 0

                    let resourceKeys: Set<URLResourceKey> = [
                        .fileSizeKey,
                        .totalFileAllocatedSizeKey,
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .volumeIsInternalKey,
                        .contentModificationDateKey,
                        .contentAccessDateKey,
                        .creationDateKey,
                        .typeIdentifierKey,
                        .isSymbolicLinkKey
                    ]

                    // Stack entries: (url, isNewToDb)
                    // isNewToDb=true forces "changed" processing regardless of mtime
                    var stack: [(url: URL, isNewToDb: Bool)] = [(rootURL, false)]

                    while let entry = stack.popLast() {
                        if Task.isCancelled { break }

                        // Yield to cooperative thread pool every 200 directories
                        // to prevent starving other tasks (especially UI)
                        dirCount += 1
                        if dirCount % 200 == 0 {
                            await Task.yield()
                        }

                        let dirURL = entry.url
                        let dirPath = dirURL.path
                        let isNewToDb = entry.isNewToDb

                        if repository.isManagedStoragePath(dirPath) {
                            continue
                        }
                        if IndexedPathRules.shouldExcludeDuringRootScan(path: dirPath, scanRootPath: rootURL.path) {
                            continue
                        }

                        // Get directory mtime
                        let dirValues = try? dirURL.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey])

                        // Skip symbolic links
                        if dirValues?.isSymbolicLink == true { continue }

                        let dirMtime = dirValues?.contentModificationDate?.timeIntervalSince1970 ?? 0
                        let isChanged = isNewToDb || dirMtime > since || dirPath == rootURL.path

                        if isChanged {
                            // CHANGED DIRECTORY: diff filesystem vs DB
                            guard let contents = try? FileManager.default.contentsOfDirectory(
                                at: dirURL,
                                includingPropertiesForKeys: Array(resourceKeys),
                                options: []
                            ) else { continue }

                            let dbChildren = try repository.existingChildrenModifiedTimes(parentPath: dirPath)
                            var fsChildPaths = Set<String>()

                            for fileURL in contents {
                                let path = fileURL.path
                                fsChildPaths.insert(path)

                                guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else { continue }

                                // Skip symbolic links
                                if values.isSymbolicLink == true {
                                    fsChildPaths.remove(path)
                                    continue
                                }

                                let isDir = values.isDirectory ?? false
                                let modifiedAt = values.contentModificationDate?.timeIntervalSince1970

                                if shouldExcludeExternalVolume(url: fileURL, isDirectory: isDir, rootURL: rootURL, values: values) {
                                    fsChildPaths.remove(path)
                                    continue
                                }
                                if IndexedPathRules.shouldExcludeDuringRootScan(path: path, scanRootPath: rootURL.path) {
                                    fsChildPaths.remove(path)
                                    continue
                                }
                                if repository.isManagedStoragePath(path) {
                                    fsChildPaths.remove(path)
                                    continue
                                }

                                // Skip sockets/devices/other non-regular entries.
                                if !isDir && values.isRegularFile != true {
                                    fsChildPaths.remove(path)
                                    continue
                                }

                                if isDir {
                                    // Push child directory onto stack
                                    let existsInDb = dbChildren[path] != nil
                                    stack.append((fileURL, !existsInDb))

                                    // Upsert if new to DB
                                    if !existsInDb {
                                        let node = FileNode(
                                            path: path,
                                            name: fileURL.lastPathComponent,
                                            parentPath: dirPath,
                                            size: 0,
                                            isDirectory: true,
                                            modifiedAt: modifiedAt,
                                            accessedAt: values.contentAccessDate?.timeIntervalSince1970,
                                            createdAt: values.creationDate?.timeIntervalSince1970,
                                            fileType: values.typeIdentifier,
                                            scanSessionId: sessionId
                                        )
                                        upsertBatch.append(node)
                                        affectedPaths.insert(path)
                                    }
                                } else {
                                    // File: upsert if new or modified
                                    if let existingModified = dbChildren[path],
                                       existingModified == modifiedAt {
                                        continue // unchanged
                                    }

                                    let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                                    let node = FileNode(
                                        path: path,
                                        name: fileURL.lastPathComponent,
                                        parentPath: dirPath,
                                        size: size,
                                        isDirectory: false,
                                        modifiedAt: modifiedAt,
                                        accessedAt: values.contentAccessDate?.timeIntervalSince1970,
                                        createdAt: values.creationDate?.timeIntervalSince1970,
                                        fileType: values.typeIdentifier,
                                        scanSessionId: sessionId
                                    )
                                    upsertBatch.append(node)
                                    affectedPaths.insert(path)
                                    progress.totalSize += size
                                }

                                progress.filesScanned += 1
                            }

                            // Find deleted paths (in DB but not on filesystem)
                            for dbPath in dbChildren.keys {
                                if !fsChildPaths.contains(dbPath) {
                                    deleteBatch.append(dbPath)
                                    affectedPaths.insert(dbPath)
                                }
                            }

                            progress.currentPath = dirURL.lastPathComponent
                        } else {
                            // UNCHANGED DIRECTORY: recurse via DB-known subdirectories.
                            // Verify each subdirectory still exists — catches bulk deletions
                            // that happened while the app was closed and weren't replayed
                            // by FSEvents (journal wrap). deleteFilesRecursive handles
                            // cascading descendant cleanup.
                            let subdirs = try repository.existingSubdirectoryPaths(parentPath: dirPath)
                            for subdirPath in subdirs {
                                if FileManager.default.fileExists(atPath: subdirPath) {
                                    stack.append((URL(fileURLWithPath: subdirPath), false))
                                } else {
                                    deleteBatch.append(subdirPath)
                                    affectedPaths.insert(subdirPath)
                                }
                            }
                        }

                        // Flush upsert batch
                        if upsertBatch.count >= batchSize {
                            try await repository.insertFilesBatch(upsertBatch)
                            upsertBatch.removeAll(keepingCapacity: true)
                            continuation.yield(progress)
                        }

                        // Flush delete batch
                        if deleteBatch.count >= 500 {
                            try await repository.deleteFilesRecursive(paths: deleteBatch)
                            deleteBatch.removeAll(keepingCapacity: true)
                        }
                    }

                    // Flush remaining
                    if !upsertBatch.isEmpty {
                        try await repository.insertFilesBatch(upsertBatch)
                    }
                    if !deleteBatch.isEmpty {
                        try await repository.deleteFilesRecursive(paths: deleteBatch)
                    }

                    // Recalculate ancestor sizes for all affected paths
                    if !affectedPaths.isEmpty {
                        try await repository.updateAncestorSizes(forPaths: affectedPaths)
                        try await repository.refreshRootDirectorySize()
                    }

                    progress.completed = true
                    continuation.yield(progress)
                    continuation.finish()
                } catch {
                    logger.error("Quick sync failed: \(error.localizedDescription, privacy: .public)")
                    continuation.yield(ScanProgress(errorMessage: error.localizedDescription))
                    continuation.finish()
                }
            }
            // Cancel the producer if the consumer side terminates
            // (e.g. incrementalSyncTask?.cancel() in AppState)
            continuation.onTermination = { @Sendable _ in producerTask.cancel() }
        }
    }

    func incrementalScan(rootURL: URL, sessionId: Int64) -> AsyncStream<ScanProgress> {
        AsyncStream { continuation in
            let producerTask = Task {
                do {
                    var progress = ScanProgress()
                    var upsertBatch: [FileNode] = []
                    var deleteBatch: [String] = []
                    var affectedPaths = Set<String>()
                    var dirCount = 0

                    let resourceKeys: Set<URLResourceKey> = [
                        .fileSizeKey,
                        .totalFileAllocatedSizeKey,
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .volumeIsInternalKey,
                        .contentModificationDateKey,
                        .contentAccessDateKey,
                        .creationDateKey,
                        .typeIdentifierKey,
                        .isSymbolicLinkKey
                    ]

                    // Iterative DFS — every directory is treated as "changed"
                    var stack: [URL] = [rootURL]

                    while let dirURL = stack.popLast() {
                        if Task.isCancelled { break }

                        // Yield to cooperative thread pool every 200 directories
                        dirCount += 1
                        if dirCount % 200 == 0 {
                            await Task.yield()
                        }

                        let dirPath = dirURL.path

                        if repository.isManagedStoragePath(dirPath) {
                            continue
                        }
                        if IndexedPathRules.shouldExcludeDuringRootScan(path: dirPath, scanRootPath: rootURL.path) {
                            continue
                        }

                        // Skip symbolic links
                        let dirValues = try? dirURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                        if dirValues?.isSymbolicLink == true { continue }

                        guard let contents = try? FileManager.default.contentsOfDirectory(
                            at: dirURL,
                            includingPropertiesForKeys: Array(resourceKeys),
                            options: []
                        ) else { continue }

                        let dbChildren = try repository.existingChildrenModifiedTimes(parentPath: dirPath)
                        var fsChildPaths = Set<String>()

                        for fileURL in contents {
                            let path = fileURL.path
                            fsChildPaths.insert(path)

                            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else { continue }

                            // Skip symbolic links
                            if values.isSymbolicLink == true {
                                fsChildPaths.remove(path)
                                continue
                            }

                            let isDir = values.isDirectory ?? false
                            let modifiedAt = values.contentModificationDate?.timeIntervalSince1970

                            if shouldExcludeExternalVolume(url: fileURL, isDirectory: isDir, rootURL: rootURL, values: values) {
                                fsChildPaths.remove(path)
                                continue
                            }
                            if IndexedPathRules.shouldExcludeDuringRootScan(path: path, scanRootPath: rootURL.path) {
                                fsChildPaths.remove(path)
                                continue
                            }
                            if repository.isManagedStoragePath(path) {
                                fsChildPaths.remove(path)
                                continue
                            }

                            // Skip sockets/devices/other non-regular entries.
                            if !isDir && values.isRegularFile != true {
                                fsChildPaths.remove(path)
                                continue
                            }

                            if isDir {
                                stack.append(fileURL)

                                // Upsert directory if new
                                if dbChildren[path] == nil {
                                    let node = FileNode(
                                        path: path,
                                        name: fileURL.lastPathComponent,
                                        parentPath: dirPath,
                                        size: 0,
                                        isDirectory: true,
                                        modifiedAt: modifiedAt,
                                        accessedAt: values.contentAccessDate?.timeIntervalSince1970,
                                        createdAt: values.creationDate?.timeIntervalSince1970,
                                        fileType: values.typeIdentifier,
                                        scanSessionId: sessionId
                                    )
                                    upsertBatch.append(node)
                                    affectedPaths.insert(path)
                                }
                            } else {
                                // Skip unchanged files
                                if let existingModified = dbChildren[path],
                                   existingModified == modifiedAt {
                                    progress.filesScanned += 1
                                    if progress.filesScanned % 5000 == 0 {
                                        progress.currentPath = fileURL.lastPathComponent
                                        continuation.yield(progress)
                                    }
                                    continue
                                }

                                let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                                let node = FileNode(
                                    path: path,
                                    name: fileURL.lastPathComponent,
                                    parentPath: dirPath,
                                    size: size,
                                    isDirectory: false,
                                    modifiedAt: modifiedAt,
                                    accessedAt: values.contentAccessDate?.timeIntervalSince1970,
                                    createdAt: values.creationDate?.timeIntervalSince1970,
                                    fileType: values.typeIdentifier,
                                    scanSessionId: sessionId
                                )
                                upsertBatch.append(node)
                                affectedPaths.insert(path)
                                progress.totalSize += size
                            }

                            progress.filesScanned += 1
                        }

                        // Deleted paths: in DB but not on filesystem
                        for dbPath in dbChildren.keys {
                            if !fsChildPaths.contains(dbPath) {
                                deleteBatch.append(dbPath)
                                affectedPaths.insert(dbPath)
                            }
                        }

                        progress.currentPath = dirURL.lastPathComponent

                        // Flush upsert batch
                        if upsertBatch.count >= batchSize {
                            try await repository.insertFilesBatch(upsertBatch)
                            upsertBatch.removeAll(keepingCapacity: true)
                            continuation.yield(progress)
                        }

                        // Flush delete batch
                        if deleteBatch.count >= 500 {
                            try await repository.deleteFilesRecursive(paths: deleteBatch)
                            deleteBatch.removeAll(keepingCapacity: true)
                        }
                    }

                    // Flush remaining
                    if !upsertBatch.isEmpty {
                        try await repository.insertFilesBatch(upsertBatch)
                    }
                    if !deleteBatch.isEmpty {
                        try await repository.deleteFilesRecursive(paths: deleteBatch)
                    }

                    // Recalculate ancestor sizes
                    if !affectedPaths.isEmpty {
                        try await repository.updateAncestorSizes(forPaths: affectedPaths)
                        try await repository.refreshRootDirectorySize()
                    }

                    progress.completed = true
                    continuation.yield(progress)
                    continuation.finish()
                } catch {
                    logger.error("Incremental scan failed: \(error.localizedDescription, privacy: .public)")
                    continuation.yield(ScanProgress(errorMessage: error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in producerTask.cancel() }
        }
    }

    func scan(rootURL: URL, sessionId: Int64) -> AsyncStream<ScanProgress> {
        AsyncStream { continuation in
            let producerTask = Task {
                do {
                    guard !repository.isManagedStoragePath(rootURL.path) else {
                        continuation.yield(ScanProgress(errorMessage: "DiskSight can't scan its own storage folder."))
                        continuation.finish()
                        return
                    }

                    var progress = ScanProgress()
                    var batch: [FileNode] = []

                    let resourceKeys: Set<URLResourceKey> = [
                        .fileSizeKey,
                        .totalFileAllocatedSizeKey,
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .volumeIsInternalKey,
                        .contentModificationDateKey,
                        .contentAccessDateKey,
                        .creationDateKey,
                        .typeIdentifierKey,
                        .isSymbolicLinkKey
                    ]

                    guard let enumerator = FileManager.default.enumerator(
                        at: rootURL,
                        includingPropertiesForKeys: Array(resourceKeys),
                        options: []
                    ) else {
                        continuation.finish()
                        return
                    }

                    // Insert root directory node
                    let rootNode = FileNode(
                        path: rootURL.path,
                        name: rootURL.lastPathComponent,
                        parentPath: nil,
                        size: 0,
                        isDirectory: true,
                        scanSessionId: sessionId
                    )
                    try await repository.insertFilesBatch([rootNode])

                    for case let fileURL as URL in enumerator {
                        if Task.isCancelled { break }

                        guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                            continue // Skip files we can't read
                        }

                        // Keep symlink policy consistent with incremental modes.
                        if values.isSymbolicLink == true {
                            if values.isDirectory == true {
                                enumerator.skipDescendants()
                            }
                            continue
                        }
                        let isDir = values.isDirectory ?? false
                        if shouldExcludeExternalVolume(url: fileURL, isDirectory: isDir, rootURL: rootURL, values: values) {
                            if isDir {
                                enumerator.skipDescendants()
                            }
                            continue
                        }
                        if IndexedPathRules.shouldExcludeDuringRootScan(path: fileURL.path, scanRootPath: rootURL.path) {
                            if isDir {
                                enumerator.skipDescendants()
                            }
                            continue
                        }
                        if repository.isManagedStoragePath(fileURL.path) {
                            if isDir {
                                enumerator.skipDescendants()
                            }
                            continue
                        }
                        if !isDir && values.isRegularFile != true {
                            continue
                        }
                        let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)

                        let node = FileNode(
                            path: fileURL.path,
                            name: fileURL.lastPathComponent,
                            parentPath: fileURL.deletingLastPathComponent().path,
                            size: isDir ? 0 : size,
                            isDirectory: isDir,
                            modifiedAt: values.contentModificationDate?.timeIntervalSince1970,
                            accessedAt: values.contentAccessDate?.timeIntervalSince1970,
                            createdAt: values.creationDate?.timeIntervalSince1970,
                            fileType: values.typeIdentifier,
                            scanSessionId: sessionId
                        )

                        batch.append(node)
                        progress.filesScanned += 1
                        if !isDir {
                            progress.totalSize += size
                        }
                        progress.currentPath = fileURL.lastPathComponent

                        if batch.count >= batchSize {
                            try await repository.insertFilesBatch(batch)
                            batch.removeAll(keepingCapacity: true)
                            continuation.yield(progress)
                        }
                    }

                    // Flush remaining
                    if !batch.isEmpty {
                        try await repository.insertFilesBatch(batch)
                    }

                    // Calculate directory sizes
                    try await repository.calculateDirectorySizes()

                    progress.completed = true
                    continuation.yield(progress)
                    continuation.finish()
                } catch {
                    logger.error("Full scan failed: \(error.localizedDescription, privacy: .public)")
                    continuation.yield(ScanProgress(errorMessage: error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in producerTask.cancel() }
        }
    }
}
