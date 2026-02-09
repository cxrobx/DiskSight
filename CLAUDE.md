# DiskSight

## Current Phase: 2

## Architecture
- **Pattern:** MVVM with SwiftUI
- **Min target:** macOS 14.0 (Sonoma)
- **Dependencies:** GRDB.swift 7.8.0 (SQLite), xxHash-Swift 1.1.1 (hashing)
- **Build:** `xcodebuild -scheme DiskSight -destination 'platform=macOS' build`

## Phase 1 (Complete)
Built project scaffold with:
- Xcode project with SPM dependency resolution
- SQLite database via GRDB with WAL mode, migrations for `files`, `scan_sessions`, `cache_patterns` tables
- `FileScanner` — async directory walker using `FileManager.enumerator`, batch inserts (1000/tx)
- `FileRepository` actor — CRUD for files, scan sessions, directory size calculation
- `Database` singleton — connection pool, migration management
- Basic SwiftUI shell: `NavigationSplitView` with sidebar sections (Overview, Visualization, Duplicates, Stale Files, Cache)
- Scan button with `NSOpenPanel` folder picker, progress reporting via `AsyncStream`, cancellation support
- `AppState` `ObservableObject` — manages scan lifecycle, section selection
- Full Disk Access entitlement + runtime permission check
- Overview placeholder showing scan progress and completion status

## Key Types
- `FileNode` — GRDB `FetchableRecord`/`PersistableRecord` for file metadata (path, size, hashes, timestamps)
- `ScanSession` — tracks scan root, timing, file count, total size, FSEvents ID
- `DuplicateGroup` — groups files by content hash with reclaimable size calc
- `AppState` — `@MainActor ObservableObject` with scan state machine (idle/scanning/completed/error)
- `FileScanner` — struct with `scan(rootURL:sessionId:) -> AsyncStream<ScanProgress>`
- `FileRepository` — actor wrapping all DB operations
- `Database` — singleton with `DatabasePool` and migration management

## Service Connections
```
DiskSightApp → AppState → FileRepository → Database (SQLite)
                        → FileScanner → FileRepository
```

## Files Created
- `DiskSight/App/DiskSightApp.swift` — @main entry, ContentView with NavigationSplitView
- `DiskSight/App/AppState.swift` — Global state, scan lifecycle management
- `DiskSight/Models/FileNode.swift` — Core file model with GRDB conformance
- `DiskSight/Models/ScanSession.swift` — Scan metadata model
- `DiskSight/Models/DuplicateGroup.swift` — Duplicate file grouping
- `DiskSight/Services/Scanner/FileScanner.swift` — Async directory walker
- `DiskSight/Services/Storage/Database.swift` — SQLite + migrations
- `DiskSight/Services/Storage/FileRepository.swift` — File CRUD operations
- `DiskSight/Views/Sidebar/SidebarView.swift` — Navigation sidebar with scan controls
- `DiskSight/Views/Overview/OverviewView.swift` — Overview with scan status
- `DiskSight/Views/Shared/SizeFormatter.swift` — Byte count formatting
- `DiskSight/Utilities/Extensions.swift` — URL, Date helpers

## Known Issues
- Directory size calculation only sums immediate children (not recursive)
- No SQL tracing toggle (always on in Database.swift)
- Package.swift in root is for reference only; actual deps managed via xcodeproj
