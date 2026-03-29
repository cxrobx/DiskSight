import Foundation
import GRDB
import OSLog

/// Orchestrates file classification by running targeted SQL queries for known cleanup
/// categories (build artifacts, caches, logs, etc.) rather than loading all files.
/// Completes in seconds even on 5M+ file databases.
actor SmartCleanupService {
    private static let logger = Logger(subsystem: "com.disksight.app", category: "SmartCleanupService")
    private let classifier: FileClassifier
    private let repository: FileRepository
    private let llmService: CleanupLLMServing?

    init(classifier: FileClassifier, repository: FileRepository, llmService: CleanupLLMServing?) {
        self.classifier = classifier
        self.repository = repository
        self.llmService = llmService
    }

    // MARK: - Rule Definitions (SQL-based)

    /// Each rule maps a category to a SQL condition on the files table.
    /// Queries target directories (is_directory=1) for path-based rules,
    /// or files by extension/name for file-level rules.
    private struct SQLRule {
        let name: String
        let category: FileCategoryType
        let confidence: DeletionConfidence
        let explanation: String
        let signals: [CleanupSignal]
        /// SQL WHERE fragment (after `scan_session_id = ? AND`)
        let condition: String
        /// Whether this rule targets directories (aggregates size) or individual files
        let isDirectoryRule: Bool
    }

    private static let rules: [SQLRule] = {
        var r: [SQLRule] = []

        // --- Build Artifacts (directory-level) ---
        r.append(SQLRule(name: "Xcode DerivedData", category: .buildArtifact, confidence: .safe,
            explanation: "Xcode build cache — regenerates on next build",
            signals: [.buildArtifact],
            condition: "is_directory = 1 AND name = 'DerivedData' AND path LIKE '%/Library/Developer/Xcode/%'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "CMake build dirs", category: .buildArtifact, confidence: .caution,
            explanation: "CMake build directory — may require reconfigure",
            signals: [.buildArtifact],
            condition: "is_directory = 1 AND name LIKE 'cmake-build-%'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "__pycache__", category: .buildArtifact, confidence: .safe,
            explanation: "Python bytecode cache — regenerates automatically",
            signals: [.buildArtifact],
            condition: "is_directory = 1 AND name = '__pycache__'",
            isDirectoryRule: true))
        r.append(SQLRule(name: ".next build cache", category: .buildArtifact, confidence: .safe,
            explanation: "Next.js build cache — regenerates on next build",
            signals: [.buildArtifact],
            condition: "is_directory = 1 AND name = '.next'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "Rust target dir", category: .buildArtifact, confidence: .caution,
            explanation: "Rust compiled output — safe but slow to rebuild",
            signals: [.buildArtifact],
            condition: "is_directory = 1 AND name = 'target' AND path LIKE '%/target' AND (SELECT COUNT(*) FROM files f2 WHERE f2.parent_path = files.path AND f2.name IN ('debug', 'release')) > 0",
            isDirectoryRule: true))
        r.append(SQLRule(name: "Gradle build output", category: .buildArtifact, confidence: .safe,
            explanation: "Gradle build output — regenerates on next build",
            signals: [.buildArtifact],
            condition: "is_directory = 1 AND name = 'build' AND parent_path LIKE '%/.gradle'",
            isDirectoryRule: true))

        // --- Caches (directory-level) ---
        r.append(SQLRule(name: "Library/Caches", category: .cache, confidence: .safe,
            explanation: "System/app cache — safe to delete, will regenerate",
            signals: [.knownCache],
            condition: "is_directory = 1 AND name = 'Caches' AND path LIKE '%/Library/Caches'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "pip cache", category: .cache, confidence: .safe,
            explanation: "pip download cache — safe to clear",
            signals: [.knownCache, .packageCache],
            condition: "is_directory = 1 AND name = 'pip' AND path LIKE '%/.cache/pip'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "npm cache", category: .cache, confidence: .safe,
            explanation: "npm download cache — safe to clear",
            signals: [.knownCache, .packageCache],
            condition: "is_directory = 1 AND name = '_cacache' AND path LIKE '%/.npm/_cacache'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "Yarn cache", category: .cache, confidence: .safe,
            explanation: "Yarn package cache — safe to clear",
            signals: [.knownCache, .packageCache],
            condition: "is_directory = 1 AND name = 'cache' AND (path LIKE '%/yarn/cache' OR path LIKE '%/.yarn/cache')",
            isDirectoryRule: true))
        r.append(SQLRule(name: "CocoaPods cache", category: .cache, confidence: .safe,
            explanation: "CocoaPods cache — safe to clear, will re-download",
            signals: [.knownCache, .packageCache],
            condition: "is_directory = 1 AND name = 'CocoaPods' AND path LIKE '%/Library/Caches/CocoaPods'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "Docker layer cache", category: .cache, confidence: .caution,
            explanation: "Docker image layer cache — clearing may require re-pulling images",
            signals: [.knownCache],
            condition: "is_directory = 1 AND (name = 'overlay2' OR name = 'buildkit') AND path LIKE '%/Docker/%'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "Spotify cache", category: .cache, confidence: .safe,
            explanation: "Spotify offline/streaming cache — safe to clear",
            signals: [.knownCache],
            condition: "is_directory = 1 AND name = 'Storage' AND path LIKE '%/com.spotify.client/Storage'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "VS Code cached data", category: .cache, confidence: .safe,
            explanation: "VS Code extension/runtime cache — safe to clear",
            signals: [.knownCache],
            condition: "is_directory = 1 AND (name = 'CachedData' OR name = 'CachedExtensions') AND path LIKE '%/Code/%'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "Homebrew cache", category: .cache, confidence: .safe,
            explanation: "Homebrew download cache — safe to clear",
            signals: [.knownCache, .packageCache],
            condition: "is_directory = 1 AND name = 'downloads' AND path LIKE '%/Homebrew/downloads'",
            isDirectoryRule: true))

        // --- Logs (directory-level) ---
        r.append(SQLRule(name: "System logs", category: .log, confidence: .safe,
            explanation: "System log directory — safe to delete, new logs will be created",
            signals: [.logFile],
            condition: "is_directory = 1 AND name = 'Logs' AND path LIKE '%/Library/Logs'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "Crash reports", category: .log, confidence: .caution,
            explanation: "Crash reports — useful for debugging, safe to delete if not needed",
            signals: [.logFile],
            condition: "is_directory = 1 AND name = 'DiagnosticReports'",
            isDirectoryRule: true))

        // --- Temporary Files (directory-level) ---
        r.append(SQLRule(name: "Trash", category: .temp, confidence: .safe,
            explanation: "Files in Trash — safe to permanently delete",
            signals: [.tempFile],
            condition: "is_directory = 1 AND name = '.Trash'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "tmp directory", category: .temp, confidence: .safe,
            explanation: "System temp directory — safe to delete",
            signals: [.tempFile],
            condition: "is_directory = 1 AND path IN ('/tmp', '/private/tmp')",
            isDirectoryRule: true))

        // --- Package Manager (directory-level) ---
        r.append(SQLRule(name: "node_modules", category: .packageManager, confidence: .caution,
            explanation: "npm/yarn packages — reinstall with 'npm install'",
            signals: [.packageCache],
            condition: "is_directory = 1 AND name = 'node_modules'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "Python venv", category: .packageManager, confidence: .caution,
            explanation: "Python virtual environment — recreate with 'python -m venv'",
            signals: [.packageCache],
            condition: "is_directory = 1 AND (name = '.venv' OR name = 'venv') AND (SELECT COUNT(*) FROM files f2 WHERE f2.parent_path = files.path AND f2.name = 'pyvenv.cfg') > 0",
            isDirectoryRule: true))
        r.append(SQLRule(name: "Pods directory", category: .packageManager, confidence: .caution,
            explanation: "CocoaPods dependencies — reinstall with 'pod install'",
            signals: [.packageCache],
            condition: "is_directory = 1 AND name = 'Pods' AND path NOT LIKE '%/Library/%'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "Cargo registry", category: .packageManager, confidence: .safe,
            explanation: "Rust crate download cache — re-downloads automatically",
            signals: [.knownCache, .packageCache],
            condition: "is_directory = 1 AND name = 'cache' AND path LIKE '%/.cargo/registry/cache'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "Maven/Gradle caches", category: .packageManager, confidence: .caution,
            explanation: "Dependency cache — re-downloads on build",
            signals: [.packageCache],
            condition: "is_directory = 1 AND name = 'caches' AND path LIKE '%/.gradle/caches'",
            isDirectoryRule: true))

        // --- Downloads (directory-level) ---
        r.append(SQLRule(name: "Downloads folder", category: .download, confidence: .caution,
            explanation: "Downloads folder — review for old installers and archives",
            signals: [.oldDownload],
            condition: "is_directory = 1 AND name = 'Downloads' AND path LIKE '%/Users/%/Downloads'",
            isDirectoryRule: true))

        // --- System Data (directory-level) ---
        r.append(SQLRule(name: "Xcode device support", category: .systemData, confidence: .caution,
            explanation: "iOS device symbols — needed for debugging specific iOS versions",
            signals: [],
            condition: "is_directory = 1 AND name IN ('iOS DeviceSupport', 'watchOS DeviceSupport')",
            isDirectoryRule: true))
        r.append(SQLRule(name: "Xcode archives", category: .systemData, confidence: .caution,
            explanation: "Xcode app archives — needed for submissions and symbolication",
            signals: [.buildArtifact],
            condition: "is_directory = 1 AND name = 'Archives' AND path LIKE '%/Xcode/Archives'",
            isDirectoryRule: true))
        r.append(SQLRule(name: "iOS simulators", category: .systemData, confidence: .caution,
            explanation: "iOS simulator data — can be re-downloaded from Xcode",
            signals: [],
            condition: "is_directory = 1 AND name = 'Devices' AND path LIKE '%/CoreSimulator/Devices'",
            isDirectoryRule: true))

        // --- Backups (directory-level) ---
        r.append(SQLRule(name: "iOS backups", category: .backup, confidence: .risky,
            explanation: "iOS device backup — delete only if you have another backup",
            signals: [],
            condition: "is_directory = 1 AND name = 'Backup' AND path LIKE '%/MobileSync/Backup'",
            isDirectoryRule: true))

        return r
    }()

    // MARK: - Analysis (SQL-based, completes in seconds)

    func analyze(sessionId: Int64, llmModel: String?) -> AsyncStream<(ClassificationProgress, [CleanupRecommendation])> {
        let repository = self.repository

        return AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let totalRules = Self.rules.count
                    var allRecs: [CleanupRecommendation] = []

                    for (index, rule) in Self.rules.enumerated() {
                        let progress = ClassificationProgress(
                            processed: index,
                            total: totalRules,
                            currentFile: rule.name
                        )
                        continuation.yield((progress, []))

                        let recs = try repository.queryCleanupRule(
                            sessionId: sessionId,
                            rule: rule.name,
                            category: rule.category,
                            confidence: rule.confidence,
                            explanation: rule.explanation,
                            signals: rule.signals,
                            condition: rule.condition,
                            isDirectoryRule: rule.isDirectoryRule
                        )
                        allRecs.append(contentsOf: recs)
                    }

                    // Final yield with all results
                    let finalProgress = ClassificationProgress(
                        processed: totalRules,
                        total: totalRules,
                        currentFile: "Complete"
                    )
                    continuation.yield((finalProgress, allRecs))

                } catch {
                    Self.logger.error("Smart cleanup analysis failed: \(error.localizedDescription, privacy: .public)")
                    continuation.yield((
                        ClassificationProgress(processed: 0, total: 0, currentFile: "Analysis failed: \(error.localizedDescription)"),
                        []
                    ))
                }
                continuation.finish()
            }
        }
    }
}
