import Foundation
import GRDB

// MARK: - Cleanup Recommendation

struct CleanupRecommendation: Identifiable {
    let id: String // file path as unique ID
    let filePath: String
    let fileName: String
    let fileSize: Int64
    let category: FileCategoryType
    let confidence: DeletionConfidence
    let explanation: String
    let signals: [CleanupSignal]
    let llmEnhanced: Bool
    let scanSessionId: Int64
    let llmRaisedConfidence: Bool

    var accessedAt: Double?
    var modifiedAt: Double?

    init(
        id: String,
        filePath: String,
        fileName: String,
        fileSize: Int64,
        category: FileCategoryType,
        confidence: DeletionConfidence,
        explanation: String,
        signals: [CleanupSignal],
        llmEnhanced: Bool,
        scanSessionId: Int64,
        llmRaisedConfidence: Bool = false,
        accessedAt: Double? = nil,
        modifiedAt: Double? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.category = category
        self.confidence = confidence
        self.explanation = explanation
        self.signals = signals
        self.llmEnhanced = llmEnhanced
        self.scanSessionId = scanSessionId
        self.llmRaisedConfidence = llmRaisedConfidence
        self.accessedAt = accessedAt
        self.modifiedAt = modifiedAt
    }
}

// MARK: - GRDB-Persistable Record

struct CleanupRecommendationRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var filePath: String
    var fileName: String
    var fileSize: Int64
    var category: String
    var confidence: String
    var explanation: String
    var signals: String // JSON-encoded array of signal raw values
    var llmEnhanced: Bool
    var scanSessionId: Int64
    var createdAt: Double
    var llmRaisedConfidence: Bool

    static let databaseTableName = "cleanup_recommendations"

    enum CodingKeys: String, CodingKey {
        case id
        case filePath = "file_path"
        case fileName = "file_name"
        case fileSize = "file_size"
        case category
        case confidence
        case explanation
        case signals
        case llmEnhanced = "llm_enhanced"
        case scanSessionId = "scan_session_id"
        case createdAt = "created_at"
        case llmRaisedConfidence = "llm_raised_confidence"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Conversion

    func toRecommendation() -> CleanupRecommendation {
        let decodedSignals: [CleanupSignal] = {
            guard let data = signals.data(using: .utf8),
                  let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return raw.compactMap { CleanupSignal(rawValue: $0) }
        }()

        return CleanupRecommendation(
            id: filePath,
            filePath: filePath,
            fileName: fileName,
            fileSize: fileSize,
            category: FileCategoryType(rawValue: category) ?? .unknown,
            confidence: DeletionConfidence(rawValue: confidence) ?? .caution,
            explanation: explanation,
            signals: decodedSignals,
            llmEnhanced: llmEnhanced,
            scanSessionId: scanSessionId,
            llmRaisedConfidence: llmRaisedConfidence
        )
    }

    static func from(_ rec: CleanupRecommendation) -> CleanupRecommendationRecord {
        let signalStrings = rec.signals.map(\.rawValue)
        let signalsJSON = (try? JSONEncoder().encode(signalStrings))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return CleanupRecommendationRecord(
            id: nil,
            filePath: rec.filePath,
            fileName: rec.fileName,
            fileSize: rec.fileSize,
            category: rec.category.rawValue,
            confidence: rec.confidence.rawValue,
            explanation: rec.explanation,
            signals: signalsJSON,
            llmEnhanced: rec.llmEnhanced,
            scanSessionId: rec.scanSessionId,
            createdAt: Date().timeIntervalSince1970,
            llmRaisedConfidence: rec.llmRaisedConfidence
        )
    }
}

// MARK: - Cleanup Summary

struct CleanupSummary {
    let totalReclaimable: Int64
    let safeReclaimable: Int64
    let cautionReclaimable: Int64
    let riskyReclaimable: Int64
    let categoryBreakdown: [(FileCategoryType, Int64, Int)]  // (category, totalSize, count)
    let totalCount: Int

    static let empty = CleanupSummary(
        totalReclaimable: 0,
        safeReclaimable: 0,
        cautionReclaimable: 0,
        riskyReclaimable: 0,
        categoryBreakdown: [],
        totalCount: 0
    )
}
