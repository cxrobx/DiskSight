import Foundation

// Probe a representative set of TCC-protected locations to determine whether
// DiskSight has Full Disk Access, and report per-path readability for the MCP
// `check_access` tool. FDA is all-or-nothing, so if every protected root that
// exists on this machine is readable, FDA is granted.
enum FullDiskAccessProbe {
    static let defaultProtectedRoots: [String] = [
        "~/Library/Mail",
        "~/Library/Safari",
        "~/Library/Application Support/com.apple.TCC",
        "~/Library/Application Support/AddressBook",
        "~/Library/Messages",
    ]

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func probe(paths: [String]?) -> [AccessResult] {
        let targets = (paths.map { $0.isEmpty ? defaultProtectedRoots : $0 }) ?? defaultProtectedRoots
        let fm = FileManager.default
        return targets.map { raw in
            let expanded = expand(raw)
            return AccessResult(path: expanded, readable: fm.isReadableFile(atPath: expanded))
        }
    }

    static func hasFullDiskAccess() -> Bool {
        let fm = FileManager.default
        var sawExisting = false
        for raw in defaultProtectedRoots {
            let path = expand(raw)
            if fm.fileExists(atPath: path) {
                sawExisting = true
                if !fm.isReadableFile(atPath: path) { return false }
            }
        }
        if sawExisting { return true }
        // No protected root present (unusual) — fall back to the classic probe.
        return fm.isReadableFile(atPath: expand("~/Library/Mail"))
    }
}

/// Tracks the single active MCP-initiated scan job and bridges socket commands
/// to AppState's @MainActor scan surface. The app is the sole DB writer, so all
/// scan control flows through here.
@MainActor
final class ScanJobRegistry {
    private weak var appState: AppState?
    private var currentJob: Job?

    private struct Job {
        let id: String
        let rootPath: String
        let mode: String
        let startedAt: Date
        var timeoutTask: Task<Void, Never>?
        var cancelled: Bool = false
    }

    init(appState: AppState) {
        self.appState = appState
    }

    func handle(_ request: ScanSocketRequest) -> ScanSocketResponse {
        switch request.command {
        case "ping":
            return ScanSocketResponse(ok: true, message: "DiskSight scan channel ready")
        case "check_access":
            return ScanSocketResponse(
                ok: true,
                access: FullDiskAccessProbe.probe(paths: request.paths),
                fullDiskAccess: FullDiskAccessProbe.hasFullDiskAccess()
            )
        case "start_scan":
            return startScan(request)
        case "scan_status":
            return scanStatus(request)
        case "cancel_scan":
            return cancelScan(request)
        default:
            return .failure("Unknown command: \(request.command)")
        }
    }

    private func startScan(_ request: ScanSocketRequest) -> ScanSocketResponse {
        guard let appState else { return .failure("App state unavailable.") }
        guard let root = request.root, !root.isEmpty else {
            return .failure("`root` is required for start_scan.")
        }
        let mode = request.mode ?? "auto"
        let jobId = UUID().uuidString

        if let error = appState.mcpTriggerScan(rootPath: root, mode: mode, jobID: jobId) {
            return .failure(error)
        }

        var job = Job(id: jobId, rootPath: root, mode: mode, startedAt: Date())

        if let maxDuration = request.maxDuration, maxDuration > 0 {
            let capped = min(maxDuration, 24 * 3600)
            job.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(capped * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                // Only cancel if THIS job's scan is still the active running one.
                if self.currentJob?.id == jobId, self.appState?.mcpActiveJobID == jobId {
                    self.appState?.mcpCancelActiveScan()
                    self.currentJob?.cancelled = true
                }
            }
        }

        currentJob = job
        return ScanSocketResponse(ok: true, job: status(for: job))
    }

    private func scanStatus(_ request: ScanSocketRequest) -> ScanSocketResponse {
        guard let job = currentJob else {
            // No in-memory job (e.g. the app relaunched between start_scan and
            // this poll). Fall back to the last completed session rather than
            // hard-failing, so an agent can still learn the scan finished.
            if let fallback = appState?.mcpLatestSessionSnapshot() {
                return ScanSocketResponse(ok: true, job: ScanJobStatus(
                    jobId: request.jobId ?? "latest",
                    state: fallback.state,
                    rootPath: appState?.lastScanSession?.rootPath ?? "",
                    mode: "unknown",
                    filesScanned: fallback.filesScanned,
                    totalSizeBytes: fallback.totalSize,
                    skippedDirectories: fallback.skipped,
                    errorMessage: nil,
                    startedAt: nil
                ))
            }
            return .failure("No scan has been started via the MCP channel.")
        }
        if let requestedId = request.jobId, requestedId != job.id {
            return .failure("Unknown job id: \(requestedId)")
        }
        return ScanSocketResponse(ok: true, job: status(for: job))
    }

    private func cancelScan(_ request: ScanSocketRequest) -> ScanSocketResponse {
        guard let appState, var job = currentJob else {
            return .failure("No scan to cancel.")
        }
        if let requestedId = request.jobId, requestedId != job.id {
            return .failure("Unknown job id: \(requestedId)")
        }
        // Only actually cancel the running scan if it is still THIS job's.
        if appState.mcpActiveJobID == job.id {
            appState.mcpCancelActiveScan()
        }
        job.timeoutTask?.cancel()
        job.cancelled = true
        currentJob = job
        return ScanSocketResponse(ok: true, job: status(for: job))
    }

    /// Resolve a job's status:
    ///  1. If it's the currently-active running scan → live snapshot.
    ///  2. Else if AppState has a latched terminal outcome for it → that.
    ///  3. Else if we locally marked it cancelled → cancelled.
    ///  4. Else it was superseded by a newer scan and its result is unknown.
    private func status(for job: Job) -> ScanJobStatus {
        func make(_ state: String, _ snap: MCPScanSnapshot?, error: String? = nil) -> ScanJobStatus {
            ScanJobStatus(
                jobId: job.id,
                state: state,
                rootPath: job.rootPath,
                mode: job.mode,
                filesScanned: snap?.filesScanned,
                totalSizeBytes: snap?.totalSize,
                skippedDirectories: snap?.skipped,
                errorMessage: error ?? snap?.error,
                startedAt: job.startedAt
            )
        }

        if appState?.mcpActiveJobID == job.id {
            let snap = appState?.mcpScanSnapshot()
            return make(snap?.state ?? "scanning", snap)
        }
        if let outcome = appState?.mcpLastJobOutcome, outcome.id == job.id {
            let snap = MCPScanSnapshot(
                state: outcome.state,
                filesScanned: outcome.filesScanned,
                totalSize: outcome.totalSize,
                skipped: outcome.skipped,
                error: outcome.error
            )
            return make(outcome.state, snap, error: outcome.error)
        }
        if job.cancelled {
            return make("cancelled", nil)
        }
        return make("unknown", nil, error: "Status unavailable — the scan was superseded by a newer scan.")
    }
}
