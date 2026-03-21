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
}
