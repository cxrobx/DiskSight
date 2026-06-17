import Foundation
import MCP
import DiskSightCore

// Scan-path MCP tools. These are app-mediated: they connect to the running
// DiskSight app over its Unix command socket so the app stays the sole DB
// writer (and reuses its Full Disk Access grant). If the app isn't running,
// the relevant tools auto-launch it and retry.

enum ScanTools {
    static func definitions() -> [Tool] {
        [
            Tool(
                name: "check_access",
                description: "Check whether DiskSight has the disk access needed to scan given paths. Returns per-path readability and an overall Full Disk Access verdict. Launches DiskSight if needed.",
                inputSchema: SchemaBuilder.object([
                    "paths": .object([
                        "type": .string("array"),
                        "description": .string("Absolute paths to check. Omit to probe representative protected locations."),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "start_scan",
                description: "Start a disk scan in the DiskSight app (the sole DB writer). Returns a job_id to poll with scan_status. Launches DiskSight if it isn't running.",
                inputSchema: SchemaBuilder.object([
                    "root": SchemaBuilder.prop("string", "Absolute path of the directory to scan."),
                    "mode": SchemaBuilder.prop("string", "auto | full | incremental (default auto). incremental requires a prior completed scan of the same root."),
                    "max_duration": SchemaBuilder.prop("number", "Optional seconds after which the scan is auto-cancelled. 0/omit = no automatic cancel."),
                ], required: ["root"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "scan_job_status",
                description: "Poll the status of a scan started with start_scan (state, files scanned, bytes, unreadable dirs). Does not launch the app.",
                inputSchema: SchemaBuilder.object([
                    "job_id": SchemaBuilder.prop("string", "The job id returned by start_scan. Omit to query the most recent job."),
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "cancel_scan",
                description: "Cancel an in-progress scan started with start_scan. Does not launch the app.",
                inputSchema: SchemaBuilder.object([
                    "job_id": SchemaBuilder.prop("string", "The job id returned by start_scan. Omit to cancel the most recent job."),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
        ]
    }

    static let names: Set<String> = Set(definitions().map(\.name))

    struct AccessReport: Encodable {
        let fullDiskAccess: Bool?
        let paths: [AccessResult]

        enum CodingKeys: String, CodingKey {
            case fullDiskAccess = "full_disk_access"
            case paths
        }
    }

    /// Handle a scan tool. Returns nil if `name` is not a scan tool.
    static func handle(name: String, arguments: [String: Value]?, client: AppSocketClient) async -> CallTool.Result? {
        guard names.contains(name) else { return nil }

        let request: ScanSocketRequest
        let autoLaunch: Bool

        switch name {
        case "check_access":
            let paths = arguments?["paths"]?.arrayValue?.compactMap { $0.stringValue }
            request = ScanSocketRequest(command: "check_access", paths: paths)
            autoLaunch = true

        case "start_scan":
            guard let root = arguments?["root"]?.stringValue, !root.isEmpty else {
                return textResult("`root` is required.", isError: true)
            }
            request = ScanSocketRequest(
                command: "start_scan",
                root: root,
                mode: arguments?["mode"]?.stringValue,
                maxDuration: arguments?["max_duration"]?.doubleValue
            )
            autoLaunch = true

        case "scan_job_status":
            request = ScanSocketRequest(command: "scan_status", jobId: arguments?["job_id"]?.stringValue)
            autoLaunch = false

        case "cancel_scan":
            request = ScanSocketRequest(command: "cancel_scan", jobId: arguments?["job_id"]?.stringValue)
            autoLaunch = false

        default:
            return nil
        }

        let response: ScanSocketResponse
        do {
            response = try await client.send(request, autoLaunch: autoLaunch)
        } catch {
            return textResult("\(error)", isError: true)
        }

        guard response.ok else {
            return textResult(response.error ?? "Scan command failed.", isError: true)
        }

        if name == "check_access" {
            return jsonResult(AccessReport(fullDiskAccess: response.fullDiskAccess, paths: response.access ?? []))
        }
        if let job = response.job {
            return jsonResult(job)
        }
        if let message = response.message {
            return textResult(message)
        }
        return textResult("ok")
    }
}
