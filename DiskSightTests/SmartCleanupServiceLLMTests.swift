import XCTest
@testable import DiskSight

private actor FakeLLMService: CleanupLLMServing {
    let responsesByPath: [String: LLMFileAnalysis]

    init(responsesByPath: [String: LLMFileAnalysis]) {
        self.responsesByPath = responsesByPath
    }

    func analyzeFiles(
        files: [(path: String, name: String, size: Int64, ext: String)],
        model: String
    ) async -> [LLMFileAnalysis] {
        files.compactMap { responsesByPath[$0.path] }
    }
}

final class SmartCleanupServiceLLMTests: XCTestCase {
    func testClaudeHeadlessExtractsJSONEnvelopeResult() {
        let stdout = """
        \u{001B}]0;Claude Code\u{0007}
        {"type":"result","result":"[{\\"path\\":\\"/tmp/cache.db\\",\\"category\\":\\"Cache\\",\\"confidence\\":\\"safe\\",\\"explanation\\":\\"App cache\\"}]"}
        """

        let extracted = ClaudeCLIClient.extractResponseText(from: stdout)
        let analyses = CleanupLLMResponseParser.parseAnalysis(from: extracted)

        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.filePath, "/tmp/cache.db")
        XCTAssertEqual(analyses.first?.category, .cache)
        XCTAssertEqual(analyses.first?.confidence, .safe)
        XCTAssertEqual(analyses.first?.explanation, "App cache")
    }

    func testClaudeHeadlessBuildsProcessEnvironment() {
        let environment = ClaudeCLIClient.buildProcessEnvironment([
            "PATH": "/usr/bin:/bin",
            "CLAUDECODE": "1",
            "CLAUDE_PROJECT": "nested"
        ])

        XCTAssertTrue(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin") ?? false)
        XCTAssertNil(environment["CLAUDECODE"])
        XCTAssertNil(environment["CLAUDE_PROJECT"])
    }

    func testAnalyzeUsesLLMEnhancementWhenModelProvided() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let databaseURL = tempDirectory.appendingPathComponent("disksight.sqlite")
        let database = try Database(databaseURL: databaseURL)
        let repository = FileRepository(database: database)

        let session = try await repository.createScanSession(rootPath: NSHomeDirectory())
        let sessionId = try XCTUnwrap(session.id)
        let oldTimestamp = Date().addingTimeInterval(-(400 * 24 * 60 * 60)).timeIntervalSince1970
        let filePath = NSHomeDirectory() + "/Library/Caches/com.example/app.log"

        let file = FileNode(
            id: nil,
            path: filePath,
            name: "app.log",
            parentPath: NSHomeDirectory() + "/Library/Caches/com.example",
            size: 2_048,
            isDirectory: false,
            modifiedAt: oldTimestamp,
            accessedAt: oldTimestamp,
            createdAt: oldTimestamp,
            contentHash: nil,
            partialHash: nil,
            fileType: nil,
            scanSessionId: sessionId
        )
        try await repository.insertFilesBatch([file])

        let llmService = FakeLLMService(
            responsesByPath: [
                filePath: LLMFileAnalysis(
                    filePath: filePath,
                    category: nil,
                    confidence: .risky,
                    explanation: "Flagged by the test LLM"
                )
            ]
        )
        let service = SmartCleanupService(
            classifier: FileClassifier(),
            repository: repository,
            llmService: llmService
        )

        let stream = await service.analyze(sessionId: sessionId, llmModel: "test-model")
        var latestRecommendations: [CleanupRecommendation] = []
        for await (_, recommendations) in stream {
            latestRecommendations = recommendations
        }

        let recommendation = try XCTUnwrap(
            latestRecommendations.first(where: { $0.filePath == filePath })
        )
        XCTAssertTrue(recommendation.llmEnhanced)
        XCTAssertEqual(recommendation.explanation, "Flagged by the test LLM")
        XCTAssertEqual(recommendation.confidence, .risky)
        XCTAssertTrue(recommendation.signals.contains(.knownCache))
    }

    func testAnalyzeDoesNotMergeSignalsFromOtherSessions() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let databaseURL = tempDirectory.appendingPathComponent("disksight.sqlite")
        let database = try Database(databaseURL: databaseURL)
        let repository = FileRepository(database: database)

        let currentSession = try await repository.createScanSession(rootPath: NSHomeDirectory())
        let currentSessionId = try XCTUnwrap(currentSession.id)
        let otherSession = try await repository.createScanSession(rootPath: NSHomeDirectory())
        let otherSessionId = try XCTUnwrap(otherSession.id)

        let currentFilePath = tempDirectory.appendingPathComponent("Foo.class").path
        let currentFile = FileNode(
            id: nil,
            path: currentFilePath,
            name: "Foo.class",
            parentPath: tempDirectory.path,
            size: 4_096,
            isDirectory: false,
            modifiedAt: nil,
            accessedAt: nil,
            createdAt: nil,
            contentHash: "shared-hash",
            partialHash: nil,
            fileType: nil,
            scanSessionId: currentSessionId
        )
        let otherFile = FileNode(
            id: nil,
            path: tempDirectory.appendingPathComponent("Bar.class").path,
            name: "Bar.class",
            parentPath: tempDirectory.path,
            size: 4_096,
            isDirectory: false,
            modifiedAt: nil,
            accessedAt: nil,
            createdAt: nil,
            contentHash: "shared-hash",
            partialHash: nil,
            fileType: nil,
            scanSessionId: otherSessionId
        )
        try await repository.insertFilesBatch([currentFile, otherFile])

        let service = SmartCleanupService(
            classifier: FileClassifier(),
            repository: repository,
            llmService: nil
        )

        let stream = await service.analyze(sessionId: currentSessionId, llmModel: nil)
        var latestRecommendations: [CleanupRecommendation] = []
        for await (_, recommendations) in stream {
            if !recommendations.isEmpty {
                latestRecommendations = recommendations
            }
        }

        let recommendation = try XCTUnwrap(
            latestRecommendations.first(where: { $0.filePath == currentFilePath })
        )
        XCTAssertFalse(recommendation.signals.contains(.duplicate))
    }
}
