import Foundation

// Wire protocol for the app-mediated scan control channel.
//
// The standalone MCP server (DiskSightMCP) and the running DiskSight app speak
// this newline-delimited JSON protocol over a Unix domain socket at
// ~/Library/Application Support/DiskSight/mcp.sock. One JSON request line in,
// one JSON response line out, connection closed.
//
// This single file is the one source of truth for the protocol: it is compiled
// into BOTH DiskSightCore (so the CLI can `import DiskSightCore`) and the app
// target. Keep these types `public` so the CLI can use them across the module
// boundary.

public struct ScanSocketRequest: Codable, Sendable {
    public var command: String          // "ping" | "check_access" | "start_scan" | "scan_status" | "cancel_scan"
    public var root: String?
    public var mode: String?            // "auto" | "full" | "incremental"
    public var maxDuration: Double?     // seconds; 0/nil = no automatic cancel
    public var jobId: String?
    public var paths: [String]?

    public init(
        command: String,
        root: String? = nil,
        mode: String? = nil,
        maxDuration: Double? = nil,
        jobId: String? = nil,
        paths: [String]? = nil
    ) {
        self.command = command
        self.root = root
        self.mode = mode
        self.maxDuration = maxDuration
        self.jobId = jobId
        self.paths = paths
    }

    enum CodingKeys: String, CodingKey {
        case command
        case root
        case mode
        case maxDuration = "max_duration"
        case jobId = "job_id"
        case paths
    }
}

public struct ScanJobStatus: Codable, Sendable {
    public var jobId: String
    public var state: String            // "scanning" | "completed" | "error" | "idle" | "cancelled"
    public var rootPath: String
    public var mode: String
    public var filesScanned: Int?
    public var totalSizeBytes: Int64?
    public var skippedDirectories: Int?
    public var errorMessage: String?
    public var startedAt: Date?

    public init(
        jobId: String,
        state: String,
        rootPath: String,
        mode: String,
        filesScanned: Int? = nil,
        totalSizeBytes: Int64? = nil,
        skippedDirectories: Int? = nil,
        errorMessage: String? = nil,
        startedAt: Date? = nil
    ) {
        self.jobId = jobId
        self.state = state
        self.rootPath = rootPath
        self.mode = mode
        self.filesScanned = filesScanned
        self.totalSizeBytes = totalSizeBytes
        self.skippedDirectories = skippedDirectories
        self.errorMessage = errorMessage
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case state
        case rootPath = "root_path"
        case mode
        case filesScanned = "files_scanned"
        case totalSizeBytes = "total_size_bytes"
        case skippedDirectories = "skipped_directories"
        case errorMessage = "error_message"
        case startedAt = "started_at"
    }
}

public struct AccessResult: Codable, Sendable {
    public var path: String
    public var readable: Bool

    public init(path: String, readable: Bool) {
        self.path = path
        self.readable = readable
    }
}

public struct ScanSocketResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var job: ScanJobStatus?
    public var access: [AccessResult]?
    public var fullDiskAccess: Bool?
    public var message: String?

    public init(
        ok: Bool,
        error: String? = nil,
        job: ScanJobStatus? = nil,
        access: [AccessResult]? = nil,
        fullDiskAccess: Bool? = nil,
        message: String? = nil
    ) {
        self.ok = ok
        self.error = error
        self.job = job
        self.access = access
        self.fullDiskAccess = fullDiskAccess
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case job
        case access
        case fullDiskAccess = "full_disk_access"
        case message
    }

    public static func failure(_ message: String) -> ScanSocketResponse {
        ScanSocketResponse(ok: false, error: message)
    }
}
