# DiskSight MCP Server

`DiskSightMCP` is a standalone [Model Context Protocol](https://modelcontextprotocol.io)
stdio server that lets an AI agent inspect DiskSight's disk index and launch
bounded scans.

It is **hybrid** by design:

- **Read tools** open the shared SQLite index **read-only, in-process**. They
  need neither the DiskSight app to be running nor Full Disk Access.
- **Scan tools** connect to the **running DiskSight app** over a Unix socket so
  the app stays the single DB writer (and reuses its Full Disk Access grant). If
  the app isn't running, scan tools auto-launch it and retry.

It is **non-destructive**: there are no trash/delete/shell/arbitrary-SQL tools.
Agents can read and scan; they cannot delete.

```
MCP client (Claude Desktop / Claude Code)
   │ spawns DiskSightMCP; MCP stdio JSON-RPC
   ▼
DiskSightMCP   (SwiftPM executable — links the MCP SDK + DiskSightCore + GRDB)
   ├─ READ tools → open shared SQLite READ-ONLY in-process (no app, no FDA)
   └─ SCAN tools → connect app Unix socket; if down → auto-launch app, retry
                       │ small JSON command over ~/Library/Application Support/DiskSight/mcp.sock (0600)
                       ▼
                  DiskSight.app  (sole DB writer; holds Full Disk Access)
```

## Build

```bash
# Build the release binary; prints its path
./scripts/build-mcp.sh

# …or build + bundle into an installed /Applications/DiskSight.app
#   (copies to Contents/Helpers/DiskSightMCP and ad-hoc signs it)
./scripts/build-mcp.sh --bundle
```

Equivalent raw commands:

```bash
swift build -c release --product DiskSightMCP
"$(swift build -c release --show-bin-path)"/DiskSightMCP   # the binary
```

The app itself is unaffected — it builds from `DiskSight.xcodeproj` exactly as
before and never links the MCP SDK:

```bash
xcodebuild -scheme DiskSight -destination 'platform=macOS' build
```

## Packaging layout

This repo's `Package.swift` vends two products that live **alongside** the Xcode
app (the app is not built from the package):

| Target | Kind | Notes |
|--------|------|-------|
| `DiskSightCore` | library | Compiles the app's verified, headless-clean read code in place (Database, FileRepository, models, analysis helpers) via an explicit `sources:` list. One source of truth; Swift 5 language mode to match the app. |
| `DiskSightMCP` | executable | The MCP stdio server. The **only** target that links the MCP SDK. Swift 6. |

GRDB is pinned to the same 7.x line the Xcode project resolves (7.8.0).

## MCP client configuration

Point your client at the built binary. For a stable path, bundle it
(`--bundle`) and use `…/DiskSight.app/Contents/Helpers/DiskSightMCP`.

```json
{
  "mcpServers": {
    "disksight": {
      "command": "/Applications/DiskSight.app/Contents/Helpers/DiskSightMCP"
    }
  }
}
```

Environment overrides (optional, for dev/testing):

| Variable | Default | Purpose |
|----------|---------|---------|
| `DISKSIGHT_DB` | `~/Library/Application Support/DiskSight/disksight.sqlite` | Database path to read. |
| `DISKSIGHT_SOCK` | `<db dir>/mcp.sock` | App command socket path. |

## Tools

### Read tools (no app / no Full Disk Access required)

| Tool | Args | Returns |
|------|------|---------|
| `scan_status` | — | Latest scan freshness: root, file count, total size, completed-at, age, in-progress flag, **skipped (unreadable) directory count**, on-disk index size. |
| `bloat_report` | `largest_limit?`, `duplicate_limit?` | File-type distribution by size + largest files + top duplicate groups (reclaimable bytes). |
| `top_paths` | `path?`, `limit?` | Largest immediate children of `path` (scan root if omitted). |
| `cleanup_candidates` | `confidence?` (safe\|caution\|risky\|keep), `limit?` | Smart-cleanup recommendations + reclaimable totals by confidence. |
| `cache_hotspots` | `limit?` | Detected cache / build-artifact hotspots with sizes + safety ratings. |
| `growth_hotspots` | `period?` ("7 Days"…"90 Days"), `limit?` | Recently-grown folders. **Cache-only** — returns `computed:false` if DiskSight hasn't computed growth for that period yet (never recomputed inside the tool). |
| `stale_files` | `threshold?` ("6 Months"…"5 Years"), `min_size_bytes?`, `limit?` | Large files not accessed in a long time. |
| `search_files` | `query` (required), `limit?` | Indexed files whose name contains `query`, largest first. |

All `limit` values default small and are **capped at 100**.

### Scan tools (app-mediated)

| Tool | Args | Behavior |
|------|------|----------|
| `check_access` | `paths?` | Per-path readability + overall Full Disk Access verdict. Launches the app if needed. |
| `start_scan` | `root` (required), `mode?` (auto\|full\|incremental), `max_duration?` (seconds) | Starts a scan in the app; returns a `job_id`. Launches the app if needed. |
| `scan_job_status` | `job_id?` | Polls a running job (state, files scanned, bytes, unreadable dirs). Does **not** launch the app. |
| `cancel_scan` | `job_id?` | Cancels the active scan. Does **not** launch the app. |

> Note: `scan_status` (read, freshness) and `scan_job_status` (poll a running
> job) are distinct tools.

## Full Disk Access

- **Reads** never need FDA — the index lives in the user's Application Support
  directory, which is readable without any TCC grant.
- **Scans** run inside the app, which is where the FDA grant lives. Without FDA,
  a scan still completes but skips unreadable directories; the skipped count is
  surfaced in `scan_status` (and `scan_job_status`) so a partial index never
  looks complete. Use `check_access` to see whether FDA is granted.

## Important caveats

- **`start_scan` replaces the whole index.** DiskSight keeps a single scan
  session, so scanning a new `root` discards the previous index (this is the
  app's existing single-index model). To refresh an existing root cheaply, use
  `mode: incremental` (or `auto`), which re-syncs in place when `root` matches
  the last completed scan.
- **Reader is strictly read-only.** It opens the database with
  `Configuration.readonly = true` (no migrations, no checkpoint), so it never
  mutates state the running app owns and observes the latest committed data.
- **One scan at a time.** `start_scan` is rejected while a scan/sync is already
  running.

## Verification

```bash
# Read path (seeded temp DB; ordering, caps, no-writes, no-index):
swift test

# Manual smoke test of the running server (reads work with the app closed):
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"s","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"scan_status","arguments":{}}}' \
  | "$(swift build --show-bin-path)"/DiskSightMCP
```

stdout is reserved for JSON-RPC; all logs go to stderr.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Read tool says "No DiskSight index found" | No scan has ever run. Open DiskSight and scan, or use `start_scan`. |
| Scan tool says the app isn't running | `scan_job_status`/`cancel_scan` don't auto-launch. Run `start_scan`/`check_access` (which do), or open DiskSight. |
| `check_access` shows `full_disk_access:false` | Grant DiskSight Full Disk Access in System Settings → Privacy & Security. |
| `growth_hotspots` returns `computed:false` | Open the Recent Growth view in DiskSight for that period once to compute + cache it. |
