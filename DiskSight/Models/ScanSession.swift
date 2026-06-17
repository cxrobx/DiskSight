import Foundation
import GRDB

struct ScanSession: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var rootPath: String
    var startedAt: Double
    var completedAt: Double?
    var fileCount: Int?
    var totalSize: Int64?
    var indexedSize: Int64?
    var lastFseventsId: Int64?
    /// Directories the scanner could not read during the most recent scan/sync.
    /// Optional so a read-only reader on a pre-v14 database (column absent)
    /// decodes it as nil rather than failing.
    var skippedDirectories: Int?

    static let databaseTableName = "scan_sessions"

    enum CodingKeys: String, CodingKey {
        case id
        case rootPath = "root_path"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case fileCount = "file_count"
        case totalSize = "total_size"
        case indexedSize = "indexed_size"
        case lastFseventsId = "last_fsevents_id"
        case skippedDirectories = "skipped_directories"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
