import Foundation

struct FileScanner {
    private let repository: FileRepository
    private let batchSize = 1000

    init(repository: FileRepository) {
        self.repository = repository
    }

    func scan(rootURL: URL, sessionId: Int64) -> AsyncStream<ScanProgress> {
        AsyncStream { continuation in
            Task {
                do {
                    // Clear existing files for a fresh scan
                    try await repository.deleteAllFiles()

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
