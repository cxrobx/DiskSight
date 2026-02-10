import Foundation

/// Orchestrates file classification by combining the deterministic rule engine
/// with existing analysis signals (duplicates, stale, cache) and optional LLM enhancement.
actor SmartCleanupService {
    private let classifier: FileClassifier
    private let repository: FileRepository
    private let ollamaClient: OllamaClient?

    init(classifier: FileClassifier, repository: FileRepository, ollamaClient: OllamaClient?) {
        self.classifier = classifier
        self.repository = repository
        self.ollamaClient = ollamaClient
    }

    /// Run the full analysis pipeline with paginated file loading:
    /// 1. Get file count (fast with index)
    /// 2. Load + classify files in pages of 5000 — yields results immediately
    /// 3. Load cross-analysis signals after classification
    /// 4. Merge signals into results
    func analyze(sessionId: Int64, useLLM: Bool) -> AsyncStream<(ClassificationProgress, [CleanupRecommendation])> {
        let classifier = self.classifier
        let repository = self.repository
        let pageSize = 5000

        return AsyncStream { continuation in
            Task {
                do {
                    // 1. Get total count (fast — uses index)
                    let totalFiles = try await repository.nonDirectoryFileCount(forSession: sessionId)
                    guard totalFiles > 0 else {
                        continuation.finish()
                        return
                    }

                    // 2. Load + classify in pages — first results appear within seconds
                    var allRecs: [CleanupRecommendation] = []
                    var processedSoFar = 0

                    for pageOffset in stride(from: 0, to: totalFiles, by: pageSize) {
                        let page = try await repository.nonDirectoryFiles(
                            forSession: sessionId, limit: pageSize, offset: pageOffset
                        )
                        guard !page.isEmpty else { break }

                        // Classify this page synchronously (pure pattern matching, fast)
                        let pageRecs = await classifier.classifyBatch(
                            files: page, sessionId: sessionId
                        )
                        allRecs.append(contentsOf: pageRecs)
                        processedSoFar += page.count

                        let progress = ClassificationProgress(
                            processed: processedSoFar,
                            total: totalFiles,
                            currentFile: page.last?.name ?? ""
                        )
                        continuation.yield((progress, pageRecs))
                    }

                    // 3. Load cross-analysis signals (best-effort, don't block on failures)
                    let duplicatePaths = (try? await self.loadDuplicatePaths(repository: repository)) ?? []
                    let stalePaths = (try? await self.loadStalePaths(repository: repository)) ?? []
                    let cachePaths = (try? await self.loadCachePaths(repository: repository)) ?? []

                    // 4. If we have any cross-analysis signals, merge them and yield updated results
                    if !duplicatePaths.isEmpty || !stalePaths.isEmpty || !cachePaths.isEmpty {
                        let enhanced = allRecs.map { rec in
                            self.mergeSignals(
                                rec,
                                isDuplicate: duplicatePaths.contains(rec.filePath),
                                isStale: stalePaths.contains(rec.filePath),
                                isCache: cachePaths.contains(rec.filePath)
                            )
                        }
                        let finalProgress = ClassificationProgress(
                            processed: totalFiles,
                            total: totalFiles,
                            currentFile: "Merging signals..."
                        )
                        continuation.yield((finalProgress, enhanced))
                    }

                } catch {
                    // Silently finish on error — caller sees whatever results were yielded
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Cross-Analysis Signal Loading

    private func loadDuplicatePaths(repository: FileRepository) async throws -> Set<String> {
        let groups = try await repository.duplicateGroups()
        var paths = Set<String>()
        for group in groups {
            for file in group.files {
                paths.insert(file.path)
            }
        }
        return paths
    }

    private func loadStalePaths(repository: FileRepository) async throws -> Set<String> {
        let sixMonthsAgo = Date().timeIntervalSince1970 - (180 * 24 * 60 * 60)
        let files = try await repository.staleFiles(accessedBefore: sixMonthsAgo, minSize: 1_048_576)
        return Set(files.map(\.path))
    }

    private func loadCachePaths(repository: FileRepository) async throws -> Set<String> {
        let detector = CacheDetector(repository: repository)
        let caches = try await detector.detectCaches()
        var paths = Set<String>()
        for cache in caches {
            for path in cache.matchedPaths {
                paths.insert(path)
            }
        }
        return paths
    }

    // MARK: - Signal Merging

    /// Merge cross-analysis signals into a recommendation, potentially boosting confidence.
    private func mergeSignals(
        _ rec: CleanupRecommendation,
        isDuplicate: Bool,
        isStale: Bool,
        isCache: Bool
    ) -> CleanupRecommendation {
        var signals = rec.signals
        var confidence = rec.confidence

        if isDuplicate && !signals.contains(.duplicate) {
            signals.append(.duplicate)
        }
        if isStale && !signals.contains(.stale) {
            signals.append(.stale)
        }
        if isCache && !signals.contains(.knownCache) {
            signals.append(.knownCache)
        }

        // Cross-signal confidence amplification:
        // Multiple independent signals pointing to "safe to delete" → boost confidence
        let boostSignals: Set<CleanupSignal> = [.stale, .duplicate, .knownCache, .buildArtifact, .tempFile]
        let matchCount = signals.filter { boostSignals.contains($0) }.count

        if matchCount >= 2 && confidence == .caution {
            confidence = .safe
        } else if matchCount >= 2 && confidence == .risky {
            confidence = .caution
        }

        return CleanupRecommendation(
            id: rec.id,
            filePath: rec.filePath,
            fileName: rec.fileName,
            fileSize: rec.fileSize,
            category: rec.category,
            confidence: confidence,
            explanation: rec.explanation,
            signals: signals,
            llmEnhanced: rec.llmEnhanced,
            scanSessionId: rec.scanSessionId,
            accessedAt: rec.accessedAt,
            modifiedAt: rec.modifiedAt
        )
    }
}
