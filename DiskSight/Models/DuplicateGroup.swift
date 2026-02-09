import Foundation

struct DuplicateGroup: Identifiable {
    let id: String // content hash
    let files: [FileNode]
    let fileSize: Int64

    var totalSize: Int64 {
        fileSize * Int64(files.count)
    }

    var reclaimableSize: Int64 {
        fileSize * Int64(files.count - 1)
    }
}
