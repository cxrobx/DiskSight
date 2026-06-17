import Foundation

/// stderr-only logging. The MCP stdio transport owns stdout for JSON-RPC, so we
/// must NEVER write log lines there.
enum Log {
    private static let handle = FileHandle.standardError

    static func line(_ message: String) {
        let stamped = "[DiskSightMCP] \(message)\n"
        if let data = stamped.data(using: .utf8) {
            handle.write(data)
        }
    }
}
