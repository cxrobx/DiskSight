import Foundation

enum CSVExporter {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func generate(from files: [FileNode]) -> String {
        var csv = "path,name,size_bytes,size_formatted,is_directory,file_type,modified_at,accessed_at,created_at\n"
        for file in files {
            csv += "\(escapeField(file.path)),\(escapeField(file.name)),\(file.size),\(escapeField(SizeFormatter.format(file.size))),\(file.isDirectory),\(escapeField(file.fileType ?? "")),\(formatTimestamp(file.modifiedAt)),\(formatTimestamp(file.accessedAt)),\(formatTimestamp(file.createdAt))\n"
        }
        return csv
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
