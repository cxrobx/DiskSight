import Foundation

enum SizeFormatter {
    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func format(_ bytes: Int) -> String {
        format(Int64(bytes))
    }
}
