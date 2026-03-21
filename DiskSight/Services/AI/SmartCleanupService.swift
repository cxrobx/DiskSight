import Foundation
import OSLog

/// Orchestrates file classification by combining the deterministic rule engine
/// with existing analysis signals (duplicates, stale, cache) and optional LLM enhancement.
actor SmartCleanupService {
    private let logger = Logger(subsystem: "com.disksight.app", category: "SmartCleanupService")
    private let classifier: FileClassifier
    private let repository: FileRepository
    private let llmService: CleanupLLMServing?

    init(classifier: FileClassifier, repository: FileRepository, llmService: CleanupLLMServing?) {
        self.classifier = classifier
        self.repository = repository
        self.llmService = llmService
    }

    /// Run the full analysis pipeline with paginated file loading:
    /// 1. Get file count (fast with index)
    /// 2. Load + classify files in pages of 5000 — yields results immediately
    /// 3. Load cross-analysis signals after classification
    /// 4. Merge signals into results
    func analyze(sessionId: Int64, llmModel: String?) -> AsyncStream<(ClassificationProgress, [CleanupRecommendation])> {
        let classifier = self.classifier
        let repository = self.repository
        let llmService = self.llmService
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
                        var pageRecs = await classifier.classifyBatch(
                            files: page, sessionId: sessionId
                        )

                        if let llmService, let llmModel, !llmModel.isEmpty, !pageRecs.isEmpty {
                            pageRecs = await self.enhanceWithLLM(
                                recommendations: pageRecs,
                                files: page,
                                llmService: llmService,
                                model: llmModel
                            )
                        }

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
                    logger.error("Smart cleanup analysis stream failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Cross-Analysis Signal Loading (SQL-only, memory-efficient)

    private func loadDuplicatePaths(repository: FileRepository) async throws -> Set<String> {
        try await repository.duplicateFilePaths()
    }

    private func loadStalePaths(repository: FileRepository) async throws -> Set<String> {
        let sixMonthsAgo = Date().timeIntervalSince1970 - (180 * 24 * 60 * 60)
        return try await repository.staleFilePaths(accessedBefore: sixMonthsAgo, minSize: 1_048_576)
    }

    private func loadCachePaths(repository: FileRepository) async throws -> Set<String> {
        try await CacheDetector.ensureDefaultPatterns(repository: repository)
        // Load cache patterns and expand them to SQL LIKE patterns
        let patterns = try await repository.allCachePatterns()
        let expandedPatterns = patterns.map { pattern in
            pattern.pattern
                .replacingOccurrences(of: "~", with: NSHomeDirectory())
                .replacingOccurrences(of: "**", with: "%")
                .replacingOccurrences(of: "*", with: "%")
        }
        return try await repository.cacheMatchingPaths(patterns: expandedPatterns)
    }

    // MARK: - LLM Enhancement

    private func enhanceWithLLM(
        recommendations: [CleanupRecommendation],
        files: [FileNode],
        llmService: CleanupLLMServing,
        model: String
    ) async -> [CleanupRecommendation] {
        let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        let candidates = recommendations.compactMap { rec -> (path: String, name: String, size: Int64, ext: String)? in
            guard let file = filesByPath[rec.filePath] else { return nil }
            let ext = (file.name as NSString).pathExtension.lowercased()
            return (path: file.path, name: file.name, size: file.size, ext: ext)
        }

        guard !candidates.isEmpty else { return recommendations }

        var analysesByPath: [String: LLMFileAnalysis] = [:]
        for chunkStart in stride(from: 0, to: candidates.count, by: 50) {
            let chunkEnd = min(chunkStart + 50, candidates.count)
            let chunk = Array(candidates[chunkStart..<chunkEnd])
            let analyses = await llmService.analyzeFiles(files: chunk, model: model)
            for analysis in analyses {
                analysesByPath[analysis.filePath] = analysis
            }
        }

        return recommendations.map { rec in
            guard let analysis = analysesByPath[rec.filePath] else { return rec }
            return mergeLLMAnalysis(rec, analysis: analysis)
        }
    }

    // MARK: - Signal Merging

    private func mergeLLMAnalysis(
        _ rec: CleanupRecommendation,
        analysis: LLMFileAnalysis
    ) -> CleanupRecommendation {
        let explanation = analysis.explanation.isEmpty ? rec.explanation : analysis.explanation
        let category = rec.category == .unknown ? (analysis.category ?? rec.category) : rec.category
        let confidence = analysis.confidence.map { max(rec.confidence, $0) } ?? rec.confidence
        let llmRaisedConfidence = analysis.confidence.map { $0 > rec.confidence } ?? false
        let isEnhanced = !analysis.explanation.isEmpty || analysis.category != nil || analysis.confidence != nil

        return CleanupRecommendation(
            id: rec.id,
            filePath: rec.filePath,
            fileName: rec.fileName,
            fileSize: rec.fileSize,
            category: category,
            confidence: confidence,
            explanation: explanation,
            signals: rec.signals,
            llmEnhanced: rec.llmEnhanced || isEnhanced,
            scanSessionId: rec.scanSessionId,
            llmRaisedConfidence: rec.llmRaisedConfidence || llmRaisedConfidence,
            accessedAt: rec.accessedAt,
            modifiedAt: rec.modifiedAt
        )
    }

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

        if !rec.llmRaisedConfidence && matchCount >= 2 && confidence == .caution {
            confidence = .safe
        } else if !rec.llmRaisedConfidence && matchCount >= 2 && confidence == .risky {
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
            llmRaisedConfidence: rec.llmRaisedConfidence,
            accessedAt: rec.accessedAt,
            modifiedAt: rec.modifiedAt
        )
    }
}
