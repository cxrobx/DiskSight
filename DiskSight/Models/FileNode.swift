import Foundation
import GRDB

struct FileNode: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var path: String
    var name: String
    var parentPath: String?
    var size: Int64
    var isDirectory: Bool
    var modifiedAt: Double?
    var accessedAt: Double?
    var createdAt: Double?
    var contentHash: String?
    var partialHash: String?
    var fileType: String?
    var scanSessionId: Int64?

    static let databaseTableName = "files"

    enum Columns: String, ColumnExpression {
        case id, path, name, parentPath = "parent_path"
        case size, isDirectory = "is_directory"
        case modifiedAt = "modified_at", accessedAt = "accessed_at", createdAt = "created_at"
        case contentHash = "content_hash", partialHash = "partial_hash"
        case fileType = "file_type", scanSessionId = "scan_session_id"
    }

    enum CodingKeys: String, CodingKey {
        case id, path, name
        case parentPath = "parent_path"
        case size
        case isDirectory = "is_directory"
        case modifiedAt = "modified_at"
        case accessedAt = "accessed_at"
        case createdAt = "created_at"
        case contentHash = "content_hash"
        case partialHash = "partial_hash"
        case fileType = "file_type"
        case scanSessionId = "scan_session_id"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
