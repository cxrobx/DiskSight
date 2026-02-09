import Foundation
import GRDB

struct DuplicateProgress: Sendable {
    var stage: DuplicateStage
    var filesProcessed: Int
    var totalFiles: Int
    var bytesProcessed: Int64
}

enum DuplicateStage: String, Sendable {
    case sizeGrouping = "Grouping by size..."
    case partialHashing = "Computing partial hashes..."
    case fullHashing = "Computing full hashes..."
    case complete = "Complete"
}

actor DuplicateFinder {
    private let repository: FileRepository

    init(repository: FileRepository) {
        self.repository = repository
    }

    func findDuplicates() -> AsyncStream<DuplicateProgress> {
        AsyncStream { continuation in
            Task {
                do {
                    // Stage 1: Find files with duplicate sizes (skip < 1KB)
                    continuation.yield(DuplicateProgress(stage: .sizeGrouping, filesProcessed: 0, totalFiles: 0, bytesProcessed: 0))

                    let sizeGroups = try await getSizeGroups()
                    let candidates = sizeGroups.flatMap { $0 }

                    guard !candidates.isEmpty else {
                        continuation.yield(DuplicateProgress(stage: .complete, filesProcessed: 0, totalFiles: 0, bytesProcessed: 0))
                        continuation.finish()
                        return
                    }

                    // Stage 2: Compute partial hashes for size-matched files
                    var processed = 0
                    let total = candidates.count

                    continuation.yield(DuplicateProgress(stage: .partialHashing, filesProcessed: 0, totalFiles: total, bytesProcessed: 0))

                    for candidate in candidates {
                        if Task.isCancelled { break }

                        let url = URL(fileURLWithPath: candidate.path)
                        guard FileManager.default.isReadableFile(atPath: candidate.path) else {
                            processed += 1
                            continue
                        }

                        if let hash = try? FileHasher.partialHash(of: url) {
                            try await repository.updatePartialHash(path: candidate.path, hash: hash)
                        }

                        processed += 1
                        if processed % 50 == 0 {
                            continuation.yield(DuplicateProgress(stage: .partialHashing, filesProcessed: processed, totalFiles: total, bytesProcessed: 0))
                        }
                    }

                    // Stage 3: Find partial hash groups, compute full hashes for matches
                    let partialGroups = try await getPartialHashGroups()
                    let fullCandidates = partialGroups.flatMap { $0 }

                    processed = 0
                    let fullTotal = fullCandidates.count
                    var bytesProcessed: Int64 = 0

                    continuation.yield(DuplicateProgress(stage: .fullHashing, filesProcessed: 0, totalFiles: fullTotal, bytesProcessed: 0))

                    for candidate in fullCandidates {
                        if Task.isCancelled { break }

                        let url = URL(fileURLWithPath: candidate.path)
                        guard FileManager.default.isReadableFile(atPath: candidate.path) else {
                            processed += 1
                            continue
                        }

                        if let hash = try? FileHasher.fullHash(of: url, progressHandler: { bytes in
                            bytesProcessed += bytes
                        }) {
                            try await repository.updateContentHash(path: candidate.path, hash: hash)
                        }

                        processed += 1
                        bytesProcessed += candidate.size

                        if processed % 10 == 0 {
                            continuation.yield(DuplicateProgress(stage: .fullHashing, filesProcessed: processed, totalFiles: fullTotal, bytesProcessed: bytesProcessed))
                        }
                    }

                    continuation.yield(DuplicateProgress(stage: .complete, filesProcessed: fullTotal, totalFiles: fullTotal, bytesProcessed: bytesProcessed))
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
        }
    }

    func getDuplicateGroups() async throws -> [DuplicateGroup] {
        try await repository.duplicateGroups()
    }

    private func getSizeGroups() async throws -> [[FileNode]] {
        try await repository.sizeMatchedFiles(minSize: 1024)
    }

    private func getPartialHashGroups() async throws -> [[FileNode]] {
        try await repository.partialHashMatchedFiles()
    }
}
