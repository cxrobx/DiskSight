# DiskSight Setup

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+ with Swift 5.9+
- Full Disk Access (recommended for complete scan coverage)

## Build

```bash
# Standard build
xcodebuild -scheme DiskSight -destination 'platform=macOS' build

# Run tests
xcodebuild -scheme DiskSight -destination 'platform=macOS' test
```

## Dependencies (SPM)

| Package | Version | Purpose |
|---------|---------|---------|
| GRDB.swift | 7.8.0 | SQLite database access |
| xxHash-Swift | 1.1.1 | Fast hashing for duplicate detection |

Dependencies are managed via Swift Package Manager and resolved in `Package.resolved`.

## Full Disk Access

For comprehensive scanning (including hidden files, caches, and system directories), grant Full Disk Access:

1. Open **System Settings > Privacy & Security > Full Disk Access**
2. Add DiskSight to the allowed list
3. Restart DiskSight

Without Full Disk Access, the app will still function but may miss ~450GB+ of hidden data (dotfiles, /private, caches).

## Database

DiskSight uses a local SQLite database via GRDB. The database is created automatically on first launch.

**Tables:**
- `files` — File metadata (path, size, dates, type, hashes)
- `scan_sessions` — Scan tracking with FSEvents resume IDs
- `cache_patterns` — Cache detection patterns (10 pre-seeded)

**Location:** Application support directory (managed by GRDB `DatabasePool`)

## Entitlements

- `com.apple.security.app-sandbox` — App sandbox (disabled for full disk access)
- `com.apple.security.files.user-selected.read-write` — File access
