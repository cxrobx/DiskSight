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

    func testAnalyzeFindsDirectoryByName() async throws {
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

        // Insert a __pycache__ directory — should be matched by the SQL rule
        let dirPath = NSHomeDirectory() + "/Projects/myapp/__pycache__"
        let dir = FileNode(
            id: nil,
            path: dirPath,
            name: "__pycache__",
            parentPath: NSHomeDirectory() + "/Projects/myapp",
            size: 50_000,
            isDirectory: true,
            modifiedAt: nil,
            accessedAt: nil,
            createdAt: nil,
            contentHash: nil,
            partialHash: nil,
            fileType: nil,
            scanSessionId: sessionId
        )
        try await repository.insertFilesBatch([dir])

        let service = SmartCleanupService(
            classifier: FileClassifier(),
            repository: repository,
            llmService: nil
        )

        let stream = await service.analyze(sessionId: sessionId, llmModel: nil)
        var allRecs: [CleanupRecommendation] = []
        for await (_, recs) in stream {
            allRecs.append(contentsOf: recs)
        }

        let recommendation = allRecs.first(where: { $0.filePath == dirPath })
        XCTAssertNotNil(recommendation, "Should find __pycache__ directory")
        XCTAssertEqual(recommendation?.category, .buildArtifact)
        XCTAssertEqual(recommendation?.confidence, .safe)
    }

    func testAnalyzeDoesNotMatchWrongSession() async throws {
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

        // Insert node_modules in OTHER session only
        let dirPath = NSHomeDirectory() + "/Projects/app/node_modules"
        let dir = FileNode(
            id: nil,
            path: dirPath,
            name: "node_modules",
            parentPath: NSHomeDirectory() + "/Projects/app",
            size: 200_000_000,
            isDirectory: true,
            modifiedAt: nil,
            accessedAt: nil,
            createdAt: nil,
            contentHash: nil,
            partialHash: nil,
            fileType: nil,
            scanSessionId: otherSessionId
        )
        try await repository.insertFilesBatch([dir])

        let service = SmartCleanupService(
            classifier: FileClassifier(),
            repository: repository,
            llmService: nil
        )

        let stream = await service.analyze(sessionId: currentSessionId, llmModel: nil)
        var allRecs: [CleanupRecommendation] = []
        for await (_, recs) in stream {
            allRecs.append(contentsOf: recs)
        }

        XCTAssertTrue(allRecs.isEmpty, "Should not find directories from other sessions")
    }
}
