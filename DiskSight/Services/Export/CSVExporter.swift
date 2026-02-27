import Foundation

enum CSVExporter {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let header = "path,name,size_bytes,size_formatted,is_directory,file_type,modified_at,accessed_at,created_at\n"

    static func generate(from files: [FileNode]) -> String {
        var csv = header
        for file in files {
            csv += csvLine(for: file)
        }
        return csv
    }

    /// Stream CSV export to a file — loads files in pages of 5000 to avoid holding
    /// the entire dataset in memory. Never holds more than one page of FileNode structs.
    static func stream(from repository: FileRepository, sessionId: Int64, to url: URL) async throws {
        let pageSize = 5000

        // Write header
        try header.write(to: url, atomically: false, encoding: .utf8)

        // Open file handle for appending
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()

        var offset = 0
        while true {
            let page = try await repository.allFiles(forSession: sessionId, limit: pageSize, offset: offset)
            guard !page.isEmpty else { break }

            var chunk = ""
            chunk.reserveCapacity(page.count * 200) // rough estimate per line
            for file in page {
                chunk += csvLine(for: file)
            }

            if let data = chunk.data(using: .utf8) {
                handle.write(data)
            }

            offset += page.count
            if page.count < pageSize { break }
        }
    }

    private static func csvLine(for file: FileNode) -> String {
        "\(escapeField(file.path)),\(escapeField(file.name)),\(file.size),\(escapeField(SizeFormatter.format(file.size))),\(file.isDirectory),\(escapeField(file.fileType ?? "")),\(formatTimestamp(file.modifiedAt)),\(formatTimestamp(file.accessedAt)),\(formatTimestamp(file.createdAt))\n"
    }

    private static func escapeField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private static func formatTimestamp(_ timestamp: Double?) -> String {
        guard let ts = timestamp else { return "" }
        return isoFormatter.string(from: Date(timeIntervalSince1970: ts))
    }
}
