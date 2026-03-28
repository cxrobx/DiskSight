import Foundation

// MARK: - Classification Rule

struct ClassificationRule {
    let name: String
    let category: FileCategoryType
    let confidence: DeletionConfidence
    let explanation: String
    let signals: [CleanupSignal]
    let matches: (FileNode) -> Bool
}

// MARK: - Classification Result

struct ClassificationResult {
    let filePath: String
    let fileName: String
    let fileSize: Int64
    let category: FileCategoryType
    let confidence: DeletionConfidence
    let explanation: String
    let signals: [CleanupSignal]
    let accessedAt: Double?
    let modifiedAt: Double?
}

// MARK: - Progress

struct ClassificationProgress: Sendable {
    let processed: Int
    let total: Int
    let currentFile: String
}

// MARK: - File Classifier (Deterministic Rule Engine)

actor FileClassifier {
    private let rules: [ClassificationRule]

    init() {
        self.rules = Self.buildRules()
    }

    /// Classify a batch of files using the rule engine.
    /// Returns an AsyncStream that reports progress and yields results.
    func classify(files: [FileNode], sessionId: Int64) -> AsyncStream<(ClassificationProgress, [CleanupRecommendation])> {
        let rules = self.rules
        return AsyncStream { continuation in
            let batchSize = 500
            var allResults: [CleanupRecommendation] = []

            for batchStart in stride(from: 0, to: files.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, files.count)
                let batch = Array(files[batchStart..<batchEnd])
                var batchResults: [CleanupRecommendation] = []

                for file in batch {
                    if let result = Self.classifyFile(file, rules: rules) {
                        batchResults.append(CleanupRecommendation(
                            id: file.path,
                            filePath: file.path,
                            fileName: file.name,
                            fileSize: file.size,
                            category: result.category,
                            confidence: result.confidence,
                            explanation: result.explanation,
                            signals: result.signals,
                            llmEnhanced: false,
                            scanSessionId: sessionId,
                            accessedAt: file.accessedAt,
                            modifiedAt: file.modifiedAt
                        ))
                    }
                }

                allResults.append(contentsOf: batchResults)

                let progress = ClassificationProgress(
                    processed: batchEnd,
                    total: files.count,
                    currentFile: batch.last?.name ?? ""
                )
                continuation.yield((progress, batchResults))
            }

            continuation.finish()
        }
    }

    /// Classify a batch of files synchronously — used by SmartCleanupService for paginated processing.
    /// Nonisolated because classification is pure computation (immutable rules, static classifyFile).
    nonisolated func classifyBatch(files: [FileNode], sessionId: Int64) -> [CleanupRecommendation] {
        files.compactMap { file -> CleanupRecommendation? in
            guard let result = Self.classifyFile(file, rules: rules) else { return nil }
            return CleanupRecommendation(
                id: file.path,
                filePath: file.path,
                fileName: file.name,
                fileSize: file.size,
                category: result.category,
                confidence: result.confidence,
                explanation: result.explanation,
                signals: result.signals,
                llmEnhanced: false,
                scanSessionId: sessionId,
                accessedAt: file.accessedAt,
                modifiedAt: file.modifiedAt
            )
        }
    }

    /// Classify a single file — returns nil if no rule matches (file is unclassifiable / should keep).
    private static func classifyFile(_ file: FileNode, rules: [ClassificationRule]) -> ClassificationResult? {
        // Find the first matching rule
        for rule in rules {
            if rule.matches(file) {
                // Age-based confidence boost: older files get higher deletion confidence
                let adjustedConfidence = ageAdjustedConfidence(
                    base: rule.confidence,
                    accessedAt: file.accessedAt,
                    modifiedAt: file.modifiedAt
                )

                var signals = rule.signals
                // Add stale signal if file hasn't been accessed in 6+ months
                if let accessed = file.accessedAt {
                    let sixMonthsAgo = Date().timeIntervalSince1970 - (180 * 24 * 60 * 60)
                    if accessed < sixMonthsAgo && !signals.contains(.stale) {
                        signals.append(.stale)
                    }
                }
                // Add large file signal if > 100MB
                if file.size > 100_000_000 && !signals.contains(.largeFile) {
                    signals.append(.largeFile)
                }

                return ClassificationResult(
                    filePath: file.path,
                    fileName: file.name,
                    fileSize: file.size,
                    category: rule.category,
                    confidence: adjustedConfidence,
                    explanation: rule.explanation,
                    signals: signals,
                    accessedAt: file.accessedAt,
                    modifiedAt: file.modifiedAt
                )
            }
        }
        return nil
    }

    /// Boost confidence for older files. Build artifacts and caches that haven't been
    /// accessed in months are safer to delete.
    private static func ageAdjustedConfidence(
        base: DeletionConfidence,
        accessedAt: Double?,
        modifiedAt: Double?
    ) -> DeletionConfidence {
        guard let accessed = accessedAt ?? modifiedAt else { return base }
        let age = Date().timeIntervalSince1970 - accessed
        let oneYear: Double = 365 * 24 * 60 * 60

        switch base {
        case .caution where age > oneYear:
            return .safe
        case .risky where age > oneYear:
            return .caution
        default:
            return base
        }
    }

    // MARK: - Rule Definitions

    private static func buildRules() -> [ClassificationRule] {
        var rules: [ClassificationRule] = []

        // --- Build Artifacts ---

        rules.append(ClassificationRule(
            name: "Xcode DerivedData",
            category: .buildArtifact,
            confidence: .safe,
            explanation: "Xcode build cache — regenerates on next build",
            signals: [.buildArtifact],
            matches: { $0.path.contains("/DerivedData/") }
        ))

        rules.append(ClassificationRule(
            name: "Xcode Build folder",
            category: .buildArtifact,
            confidence: .safe,
            explanation: "Xcode build output — regenerates on next build",
            signals: [.buildArtifact],
            matches: { $0.path.contains("/Build/Products/") || $0.path.contains("/Build/Intermediates") }
        ))

        rules.append(ClassificationRule(
            name: ".o object files",
            category: .buildArtifact,
            confidence: .safe,
            explanation: "Compiled object file — regenerates on next build",
            signals: [.buildArtifact],
            matches: { $0.name.hasSuffix(".o") && $0.path.contains("/Build/") }
        ))

        rules.append(ClassificationRule(
            name: "Swift module cache",
            category: .buildArtifact,
            confidence: .safe,
            explanation: "Swift module cache — regenerates automatically",
            signals: [.buildArtifact],
            matches: { $0.path.contains("/ModuleCache.noindex/") || $0.name.hasSuffix(".swiftmodule") && $0.path.contains("/DerivedData/") }
        ))

        rules.append(ClassificationRule(
            name: "CMake build dirs",
            category: .buildArtifact,
            confidence: .caution,
            explanation: "CMake build directory — may require reconfigure to rebuild",
            signals: [.buildArtifact],
            matches: { $0.path.contains("/cmake-build-") || ($0.name == "CMakeCache.txt") }
        ))

        rules.append(ClassificationRule(
            name: "Gradle build output",
            category: .buildArtifact,
            confidence: .safe,
            explanation: "Gradle build output — regenerates on next build",
            signals: [.buildArtifact],
            matches: { $0.path.contains("/build/outputs/") && $0.path.contains("/.gradle/") || $0.path.contains("/build/intermediates/") }
        ))

        rules.append(ClassificationRule(
            name: ".class files",
            category: .buildArtifact,
            confidence: .safe,
            explanation: "Compiled Java/Kotlin class — regenerates on build",
            signals: [.buildArtifact],
            matches: { $0.name.hasSuffix(".class") }
        ))

        rules.append(ClassificationRule(
            name: "__pycache__",
            category: .buildArtifact,
            confidence: .safe,
            explanation: "Python bytecode cache — regenerates automatically",
            signals: [.buildArtifact],
            matches: { $0.path.contains("/__pycache__/") || $0.name.hasSuffix(".pyc") }
        ))

        rules.append(ClassificationRule(
            name: ".next build cache",
            category: .buildArtifact,
            confidence: .safe,
            explanation: "Next.js build cache — regenerates on next build",
            signals: [.buildArtifact],
            matches: { $0.path.contains("/.next/cache/") }
        ))

        rules.append(ClassificationRule(
            name: "Rust target dir",
            category: .buildArtifact,
            confidence: .caution,
            explanation: "Rust compiled output — safe but slow to rebuild",
            signals: [.buildArtifact],
            matches: { $0.path.contains("/target/debug/") || $0.path.contains("/target/release/") }
        ))

        // --- Caches ---

        rules.append(ClassificationRule(
            name: "Library/Caches",
            category: .cache,
            confidence: .safe,
            explanation: "System/app cache — safe to delete, will regenerate",
            signals: [.knownCache],
            matches: { $0.path.contains("/Library/Caches/") }
        ))

        rules.append(ClassificationRule(
            name: "Homebrew cache",
            category: .cache,
            confidence: .safe,
            explanation: "Homebrew download cache — safe to clear",
            signals: [.knownCache, .packageCache],
            matches: { $0.path.contains("/Homebrew/downloads/") || $0.path.contains("/Library/Caches/Homebrew/") }
        ))

        rules.append(ClassificationRule(
            name: "pip cache",
            category: .cache,
            confidence: .safe,
            explanation: "pip download cache — safe to clear",
            signals: [.knownCache, .packageCache],
            matches: { $0.path.contains("/.cache/pip/") }
        ))

        rules.append(ClassificationRule(
            name: "npm cache",
            category: .cache,
            confidence: .safe,
            explanation: "npm download cache — safe to clear",
            signals: [.knownCache, .packageCache],
            matches: { $0.path.contains("/.npm/_cacache/") }
        ))

        rules.append(ClassificationRule(
            name: "yarn cache",
            category: .cache,
            confidence: .safe,
            explanation: "Yarn package cache — safe to clear",
            signals: [.knownCache, .packageCache],
            matches: { $0.path.contains("/yarn/cache/") || $0.path.contains("/.yarn/cache/") }
        ))

        rules.append(ClassificationRule(
            name: "CocoaPods cache",
            category: .cache,
            confidence: .safe,
            explanation: "CocoaPods cache — safe to clear, will re-download",
            signals: [.knownCache, .packageCache],
            matches: { $0.path.contains("/Library/Caches/CocoaPods/") }
        ))

        rules.append(ClassificationRule(
            name: "VS Code cached data",
            category: .cache,
            confidence: .safe,
            explanation: "VS Code extension/runtime cache — safe to clear",
            signals: [.knownCache],
            matches: { $0.path.contains("/Code/CachedData/") || $0.path.contains("/Code/CachedExtensions/") }
        ))

        rules.append(ClassificationRule(
            name: "Docker overlay cache",
            category: .cache,
            confidence: .caution,
            explanation: "Docker image layer cache — clearing may require re-pulling images",
            signals: [.knownCache],
            matches: { $0.path.contains("/Docker/") && ($0.path.contains("/overlay2/") || $0.path.contains("/buildkit/")) }
        ))

        rules.append(ClassificationRule(
            name: "Spotify cache",
            category: .cache,
            confidence: .safe,
            explanation: "Spotify offline/streaming cache — safe to clear",
            signals: [.knownCache],
            matches: { $0.path.contains("/com.spotify.client/") && $0.path.contains("/Storage/") }
        ))

        rules.append(ClassificationRule(
            name: "Browser cache",
            category: .cache,
            confidence: .safe,
            explanation: "Browser cache — safe to clear, will re-download",
            signals: [.knownCache],
            matches: {
                let p = $0.path
                return (p.contains("/Google/Chrome/") || p.contains("/Firefox/") || p.contains("/Safari/") || p.contains("/BraveSoftware/"))
                    && (p.contains("/Cache/") || p.contains("/GPUCache/") || p.contains("/Service Worker/CacheStorage/"))
            }
        ))

        // --- Logs ---

        rules.append(ClassificationRule(
            name: "System logs",
            category: .log,
            confidence: .safe,
            explanation: "System log file — safe to delete, new logs will be created",
            signals: [.logFile],
            matches: { $0.path.contains("/Library/Logs/") }
        ))

        rules.append(ClassificationRule(
            name: ".log files",
            category: .log,
            confidence: .safe,
            explanation: "Log file — safe to delete",
            signals: [.logFile],
            matches: { $0.name.hasSuffix(".log") || $0.name.hasSuffix(".log.gz") }
        ))

        rules.append(ClassificationRule(
            name: "Crash reports",
            category: .log,
            confidence: .caution,
            explanation: "Crash report — useful for debugging, but safe to delete if not needed",
            signals: [.logFile],
            matches: { $0.path.contains("/DiagnosticReports/") || $0.name.hasSuffix(".crash") || $0.name.hasSuffix(".ips") }
        ))

        // --- Temporary Files ---

        rules.append(ClassificationRule(
            name: "tmp directory",
            category: .temp,
            confidence: .safe,
            explanation: "Temporary file — safe to delete",
            signals: [.tempFile],
            matches: { $0.path.hasPrefix("/tmp/") || $0.path.hasPrefix("/private/tmp/") || $0.path.contains("/T/") }
        ))

        rules.append(ClassificationRule(
            name: ".tmp files",
            category: .temp,
            confidence: .safe,
            explanation: "Temporary file — safe to delete",
            signals: [.tempFile],
            matches: { $0.name.hasSuffix(".tmp") || $0.name.hasSuffix(".temp") || $0.name.hasPrefix(".~") }
        ))

        rules.append(ClassificationRule(
            name: "Trash",
            category: .temp,
            confidence: .safe,
            explanation: "File already in Trash — safe to permanently delete",
            signals: [.tempFile],
            matches: { $0.path.contains("/.Trash/") }
        ))

        rules.append(ClassificationRule(
            name: "macOS .DS_Store",
            category: .temp,
            confidence: .safe,
            explanation: "Finder metadata file — regenerates automatically",
            signals: [.tempFile],
            matches: { $0.name == ".DS_Store" }
        ))

        rules.append(ClassificationRule(
            name: "Thumbs.db / desktop.ini",
            category: .temp,
            confidence: .safe,
            explanation: "Windows metadata file — not needed on macOS",
            signals: [.tempFile],
            matches: { $0.name == "Thumbs.db" || $0.name == "desktop.ini" }
        ))

        // --- Package Manager ---

        rules.append(ClassificationRule(
            name: "node_modules",
            category: .packageManager,
            confidence: .caution,
            explanation: "npm/yarn packages — reinstall with 'npm install'",
            signals: [.packageCache],
            matches: { $0.path.contains("/node_modules/") }
        ))

        rules.append(ClassificationRule(
            name: "Python venv",
            category: .packageManager,
            confidence: .caution,
            explanation: "Python virtual environment — recreate with 'python -m venv'",
            signals: [.packageCache],
            matches: { $0.path.contains("/.venv/") || $0.path.contains("/venv/") && $0.path.contains("/lib/python") }
        ))

        rules.append(ClassificationRule(
            name: "Cargo registry",
            category: .packageManager,
            confidence: .safe,
            explanation: "Rust crate download cache — re-downloads automatically",
            signals: [.knownCache, .packageCache],
            matches: { $0.path.contains("/.cargo/registry/cache/") }
        ))

        rules.append(ClassificationRule(
            name: "Maven repository",
            category: .packageManager,
            confidence: .caution,
            explanation: "Maven/Gradle dependency cache — re-downloads on build",
            signals: [.packageCache],
            matches: { $0.path.contains("/.m2/repository/") || $0.path.contains("/.gradle/caches/") }
        ))

        rules.append(ClassificationRule(
            name: "Pods directory",
            category: .packageManager,
            confidence: .caution,
            explanation: "CocoaPods dependencies — reinstall with 'pod install'",
            signals: [.packageCache],
            matches: { $0.path.contains("/Pods/") && !$0.path.contains("/Library/") }
        ))

        // --- Downloads ---

        rules.append(ClassificationRule(
            name: "DMG files",
            category: .download,
            confidence: .caution,
            explanation: "Disk image installer — likely no longer needed after app install",
            signals: [.oldDownload],
            matches: { $0.name.hasSuffix(".dmg") }
        ))

        rules.append(ClassificationRule(
            name: "PKG installers",
            category: .download,
            confidence: .caution,
            explanation: "Package installer — likely no longer needed after install",
            signals: [.oldDownload],
            matches: { $0.name.hasSuffix(".pkg") }
        ))

        rules.append(ClassificationRule(
            name: "ZIP archives in Downloads",
            category: .download,
            confidence: .caution,
            explanation: "Archive in Downloads — may have already been extracted",
            signals: [.oldDownload],
            matches: { $0.path.contains("/Downloads/") && ($0.name.hasSuffix(".zip") || $0.name.hasSuffix(".tar.gz") || $0.name.hasSuffix(".tgz")) }
        ))

        // --- Backups ---

        rules.append(ClassificationRule(
            name: "iOS backups",
            category: .backup,
            confidence: .risky,
            explanation: "iOS device backup — delete only if you have another backup",
            signals: [],
            matches: { $0.path.contains("/MobileSync/Backup/") }
        ))

        rules.append(ClassificationRule(
            name: "Time Machine local snapshots",
            category: .backup,
            confidence: .risky,
            explanation: "Time Machine local snapshot data — macOS manages these automatically",
            signals: [],
            matches: { $0.path.contains("/.MobileBackups/") || $0.path.contains("/Backups.backupdb/") }
        ))

        // --- System Data ---

        rules.append(ClassificationRule(
            name: "Xcode device support",
            category: .systemData,
            confidence: .caution,
            explanation: "iOS device symbols — needed for debugging specific iOS versions",
            signals: [],
            matches: { $0.path.contains("/Xcode/iOS DeviceSupport/") || $0.path.contains("/Xcode/watchOS DeviceSupport/") }
        ))

        rules.append(ClassificationRule(
            name: "Xcode archives",
            category: .systemData,
            confidence: .caution,
            explanation: "Xcode app archive — needed for App Store submissions and crash symbolication",
            signals: [.buildArtifact],
            matches: { $0.path.contains("/Xcode/Archives/") }
        ))

        rules.append(ClassificationRule(
            name: "Xcode simulators",
            category: .systemData,
            confidence: .caution,
            explanation: "iOS simulator runtime — can be re-downloaded from Xcode",
            signals: [],
            matches: { $0.path.contains("/CoreSimulator/Devices/") || $0.path.contains("/CoreSimulator/Caches/") }
        ))

        rules.append(ClassificationRule(
            name: "Application Support data",
            category: .systemData,
            confidence: .keep,
            explanation: "Application settings and data — may contain important configuration",
            signals: [],
            matches: { $0.path.contains("/Application Support/") && !$0.path.contains("/Caches/") && !$0.path.contains("/Cache/") }
        ))

        // --- Media (informational, usually keep) ---

        rules.append(ClassificationRule(
            name: "Video files",
            category: .media,
            confidence: .keep,
            explanation: "Video file — review before deleting",
            signals: [],
            matches: {
                let ext = ($0.name as NSString).pathExtension.lowercased()
                return ["mp4", "mov", "avi", "mkv", "wmv", "m4v", "flv", "webm"].contains(ext)
            }
        ))

        rules.append(ClassificationRule(
            name: "Large image collections",
            category: .media,
            confidence: .keep,
            explanation: "Image file — review before deleting",
            signals: [],
            matches: {
                let ext = ($0.name as NSString).pathExtension.lowercased()
                return ["png", "jpg", "jpeg", "heic", "tiff", "raw", "cr2", "nef", "psd"].contains(ext) && $0.size > 10_000_000
            }
        ))

        // --- Documents (informational, usually keep) ---

        rules.append(ClassificationRule(
            name: "Documents",
            category: .document,
            confidence: .keep,
            explanation: "Document file — contains user data",
            signals: [],
            matches: {
                let ext = ($0.name as NSString).pathExtension.lowercased()
                return ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "keynote"].contains(ext)
            }
        ))

        // --- Source Code (informational, usually keep) ---

        rules.append(ClassificationRule(
            name: "Source code",
            category: .sourceCode,
            confidence: .keep,
            explanation: "Source code file — likely part of a project",
            signals: [],
            matches: {
                let ext = ($0.name as NSString).pathExtension.lowercased()
                return ["swift", "py", "js", "ts", "rs", "go", "java", "kt", "c", "cpp", "h", "rb", "php"].contains(ext)
                    && !$0.path.contains("/node_modules/")
                    && !$0.path.contains("/.venv/")
                    && !$0.path.contains("/DerivedData/")
            }
        ))

        return rules
    }
}
