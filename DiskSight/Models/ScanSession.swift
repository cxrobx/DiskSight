import Foundation
import GRDB

struct ScanSession: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var rootPath: String
    var startedAt: Double
    var completedAt: Double?
    var fileCount: Int?
    var totalSize: Int64?
    var lastFseventsId: Int64?

    static let databaseTableName = "scan_sessions"

    enum CodingKeys: String, CodingKey {
        case id
        case rootPath = "root_path"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case fileCount = "file_count"
        case totalSize = "total_size"
        case lastFseventsId = "last_fsevents_id"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
