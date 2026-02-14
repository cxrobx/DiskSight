import Foundation

struct FileScanner {
    private let repository: FileRepository
    private let batchSize = 1000

    init(repository: FileRepository) {
        self.repository = repository
    }

    func incrementalScan(rootURL: URL, sessionId: Int64) -> AsyncStream<ScanProgress> {
        AsyncStream { continuation in
            Task {
                do {
                    var progress = ScanProgress()
                    var batch: [FileNode] = []
                    var upsertCount = 0

                    // Build lookup of existing paths → modifiedAt (cursor-based, no full FileNode load)
                    let existingFiles = try repository.existingFileModifiedTimes()
                    var seenPaths = Set<String>()

                    let resourceKeys: Set<URLResourceKey> = [
                        .fileSizeKey,
                        .isDirectoryKey,
                        .contentModificationDateKey,
                        .contentAccessDateKey,
                        .creationDateKey,
                        .typeIdentifierKey
                    ]

                    guard let enumerator = FileManager.default.enumerator(
                        at: rootURL,
                        includingPropertiesForKeys: Array(resourceKeys),
                        options: []
                    ) else {
                        continuation.finish()
                        return
                    }

                    // Track root
                    seenPaths.insert(rootURL.path)

                    for case let fileURL as URL in enumerator {
                        if Task.isCancelled { break }

                        let path = fileURL.path
                        seenPaths.insert(path)
                        progress.filesScanned += 1

                        guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                            continue
                        }

                        let isDir = values.isDirectory ?? false

                        if isDir {
                            // Only upsert new directories; existing ones get sizes recalculated
                            if existingFiles[path] != nil {
                                if progress.filesScanned % 5000 == 0 {
                                    progress.currentPath = fileURL.lastPathComponent
                                    continuation.yield(progress)
                                }
                                continue
                            }
                        } else {
                            // Skip unchanged files (same modifiedAt)
                            let modifiedAt = values.contentModificationDate?.timeIntervalSince1970
                            if let existingModified = existingFiles[path],
                               existingModified == modifiedAt {
                                if progress.filesScanned % 5000 == 0 {
                                    progress.currentPath = fileURL.lastPathComponent
                                    continuation.yield(progress)
                                }
                                continue
                            }
                        }

                        let size = Int64(values.fileSize ?? 0)
                        let node = FileNode(
                            path: path,
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
                        upsertCount += 1
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

                    // Flush remaining upserts
                    if !batch.isEmpty {
                        try await repository.insertFilesBatch(batch)
                    }

                    // Delete files that no longer exist on disk
                    let removedPaths = Set(existingFiles.keys).subtracting(seenPaths)
                    if !removedPaths.isEmpty {
                        try await repository.deleteFiles(paths: Array(removedPaths))
                    }

                    // Recalculate directory sizes if anything changed
                    if upsertCount > 0 || !removedPaths.isEmpty {
                        try await repository.calculateDirectorySizes()
                    }

                    continuation.yield(progress)
                    continuation.finish()
                } catch {
                    print("FileScanner incremental error: \(error)")
                    continuation.finish()
                }
            }
        }
    }

    func scan(rootURL: URL, sessionId: Int64) -> AsyncStream<ScanProgress> {
        AsyncStream { continuation in
            Task {
                do {
                    var progress = ScanProgress()
                    var batch: [FileNode] = []

                    let resourceKeys: Set<URLResourceKey> = [
                        .fileSizeKey,
                        .isDirectoryKey,
                        .contentModificationDateKey,
                        .contentAccessDateKey,
                        .creationDateKey,
                        .typeIdentifierKey
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
                        let isDir = values.isDirectory ?? false
                        let size = Int64(values.fileSize ?? 0)

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

                    continuation.yield(progress)
                    continuation.finish()
                } catch {
                    print("FileScanner error: \(error)")
                    continuation.finish()
                }
            }
        }
    }
}
