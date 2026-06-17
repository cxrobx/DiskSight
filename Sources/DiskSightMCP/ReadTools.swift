import Foundation
import MCP
import DiskSightCore

// Read-path MCP tools. These open the shared database READ-ONLY and require
// neither the app to be running nor Full Disk Access (the index is owned by the
// user under Application Support).

enum SchemaBuilder {
    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        var dict: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            dict["required"] = .array(required.map { .string($0) })
        }
        return .object(dict)
    }

    static func prop(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }
}

func textResult(_ text: String, isError: Bool = false) -> CallTool.Result {
    .init(content: [.text(text)], isError: isError)
}

func jsonResult<T: Encodable>(_ value: T) -> CallTool.Result {
    do {
        return textResult(try JSON.encode(value))
    } catch {
        return textResult("Failed to encode result: \(error)", isError: true)
    }
}

enum ReadTools {
    static let limitDesc = "Max items to return (default small, capped at 100)."

    static func definitions() -> [Tool] {
        [
            Tool(
                name: "scan_status",
                description: "Freshness and summary of the latest DiskSight scan: root path, file count, total size, when it completed, how stale it is, whether a scan is in progress, and the on-disk index size.",
                inputSchema: SchemaBuilder.object([:]),
                annotations: .init(readOnlyHint: true, idempotentHint: true)
            ),
            Tool(
                name: "bloat_report",
                description: "Headline disk-bloat snapshot: file-type distribution by size, the largest files, and the top duplicate groups (with reclaimable bytes).",
                inputSchema: SchemaBuilder.object([
                    "largest_limit": SchemaBuilder.prop("integer", "How many largest files to include (default 20, max 100)."),
                    "duplicate_limit": SchemaBuilder.prop("integer", "How many duplicate groups to include (default 25, max 100)."),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true)
            ),
            Tool(
                name: "top_paths",
                description: "Largest immediate children (files and folders) under a path. Omit `path` to list the largest items at the scan root.",
                inputSchema: SchemaBuilder.object([
                    "path": SchemaBuilder.prop("string", "Absolute directory path to list children of. Omit for the scan root."),
                    "limit": SchemaBuilder.prop("integer", limitDesc),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true)
            ),
            Tool(
                name: "cleanup_candidates",
                description: "Smart-cleanup recommendations for the latest scan: reclaimable totals by confidence plus per-file candidates. Read-only — never deletes anything.",
                inputSchema: SchemaBuilder.object([
                    "confidence": SchemaBuilder.prop("string", "Filter by confidence: safe | caution | risky | keep. Omit for all."),
                    "limit": SchemaBuilder.prop("integer", limitDesc),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true)
            ),
            Tool(
                name: "cache_hotspots",
                description: "Detected cache/build-artifact hotspots (Xcode DerivedData, node_modules, package caches, etc.) with sizes and safety ratings.",
                inputSchema: SchemaBuilder.object([
                    "limit": SchemaBuilder.prop("integer", limitDesc),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true)
            ),
            Tool(
                name: "growth_hotspots",
                description: "Folders that grew most recently. CACHE-ONLY: returns computed=false if DiskSight has not yet computed growth for the given period (it is never recomputed inside this tool).",
                inputSchema: SchemaBuilder.object([
                    "period": SchemaBuilder.prop("string", "One of: \"7 Days\", \"14 Days\", \"30 Days\", \"90 Days\" (default \"30 Days\")."),
                    "limit": SchemaBuilder.prop("integer", limitDesc),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true)
            ),
            Tool(
                name: "stale_files",
                description: "Large files not accessed in a long time (candidates for archival/deletion).",
                inputSchema: SchemaBuilder.object([
                    "threshold": SchemaBuilder.prop("string", "One of: \"6 Months\", \"1 Year\", \"2 Years\", \"5 Years\" (default \"1 Year\")."),
                    "min_size_bytes": SchemaBuilder.prop("integer", "Minimum file size in bytes (default 1048576 = 1 MB)."),
                    "limit": SchemaBuilder.prop("integer", limitDesc),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true)
            ),
            Tool(
                name: "search_files",
                description: "Find indexed files whose name contains the query, largest first.",
                inputSchema: SchemaBuilder.object([
                    "query": SchemaBuilder.prop("string", "Substring to match against file names."),
                    "limit": SchemaBuilder.prop("integer", limitDesc),
                ], required: ["query"]),
                annotations: .init(readOnlyHint: true, idempotentHint: true)
            ),
        ]
    }

    static let names: Set<String> = Set(definitions().map(\.name))

    /// Handle a read tool. Returns nil if `name` is not a read tool.
    static func handle(name: String, arguments: [String: Value]?, provider: ReaderProvider) async -> CallTool.Result? {
        guard names.contains(name) else { return nil }

        let reader: DiskSightReader
        do {
            reader = try await provider.reader()
        } catch let error as DiskSightReaderError {
            return textResult(error.description)
        } catch {
            return textResult("Could not open the DiskSight index: \(error)", isError: true)
        }

        do {
            switch name {
            case "scan_status":
                return jsonResult(try reader.scanStatus())

            case "bloat_report":
                return jsonResult(try reader.bloatReport(
                    largestLimit: arguments?["largest_limit"]?.intValue,
                    duplicateLimit: arguments?["duplicate_limit"]?.intValue
                ))

            case "top_paths":
                return jsonResult(try reader.topPaths(
                    path: arguments?["path"]?.stringValue,
                    limit: arguments?["limit"]?.intValue
                ))

            case "cleanup_candidates":
                return jsonResult(try reader.cleanupCandidates(
                    confidence: arguments?["confidence"]?.stringValue,
                    limit: arguments?["limit"]?.intValue
                ))

            case "cache_hotspots":
                return jsonResult(try await reader.cacheHotspots(
                    limit: arguments?["limit"]?.intValue
                ))

            case "growth_hotspots":
                return jsonResult(try reader.growthHotspots(
                    period: arguments?["period"]?.stringValue,
                    limit: arguments?["limit"]?.intValue
                ))

            case "stale_files":
                let minSize = arguments?["min_size_bytes"]?.intValue.map(Int64.init)
                return jsonResult(try reader.staleFiles(
                    threshold: arguments?["threshold"]?.stringValue,
                    minSizeBytes: minSize,
                    limit: arguments?["limit"]?.intValue
                ))

            case "search_files":
                guard let query = arguments?["query"]?.stringValue, !query.isEmpty else {
                    return textResult("`query` is required.", isError: true)
                }
                return jsonResult(try reader.searchFiles(
                    query: query,
                    limit: arguments?["limit"]?.intValue
                ))

            default:
                return nil
            }
        } catch let error as DiskSightReaderError {
            return textResult(error.description)
        } catch {
            return textResult("Tool \(name) failed: \(error)", isError: true)
        }
    }
}
