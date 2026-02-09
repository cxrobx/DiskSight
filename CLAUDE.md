# DiskSight

## Project Overview
Native macOS disk usage visualization and analysis app. Scans directories, visualizes with Treemap/Sunburst/Icicle, detects duplicates, stale files, and caches. Real-time FSEvents monitoring.

## Tech Stack
| Component | Technology |
|-----------|------------|
| Language | Swift |
| UI | SwiftUI (MVVM) |
| Platform | macOS 14.0+ (Sonoma) |
| Database | SQLite via GRDB.swift 7.8.0 |
| Hashing | xxHash-Swift 1.1.1 |
| Bundle ID | com.disksight.app |

## Golden Commands
```bash
# Build
xcodebuild -scheme DiskSight -destination 'platform=macOS' build

# Test
xcodebuild -scheme DiskSight -destination 'platform=macOS' test
```

## Critical Invariants (DO NOT BREAK)
1. **AppState is @MainActor** — all `@Published` properties, views access via `@EnvironmentObject`
2. **FileRepository is an actor** — all DB access goes through it, never call GRDB directly
3. **View data cached on AppState** — `loadXxx()` no-ops if data exists, `invalidateCache()` clears all
4. **Trash-based deletion only** — never use `removeItem`, users expect recoverability
5. **Database is a singleton** — `Database.shared` owns the pool, migrations run on init

Full list in `.claude/rules/architecture.md`

## Documentation Index
| File | Purpose | Loaded |
|------|---------|--------|
| `.claude/rules/architecture.md` | System patterns, invariants | Always |
| `.claude/rules/gotchas.md` | Known issues (11 items) | Always |
| `docs/README.md` | Documentation index | On demand |
| `docs/setup.md` | Build & environment setup | On demand |
| `CHANGELOG.md` | Version history | On demand |

## Key Types
| Type | Role | File |
|------|------|------|
| `AppState` | Central state + cached view data | `App/AppState.swift` |
| `FileRepository` | Actor for all DB operations | `Services/Storage/FileRepository.swift` |
| `FileScanner` | Async directory walker | `Services/Scanner/FileScanner.swift` |
| `FSEventsMonitor` | C API bridge with debounce | `Services/Monitor/FSEventsMonitor.swift` |
| `DuplicateFinder` | 3-stage hash pipeline | `Services/Analysis/DuplicateFinder.swift` |

## Service Connections
```
DiskSightApp
 └─ AppState
     ├─ FileRepository ← Database (SQLite/GRDB)
     ├─ FileScanner → FileRepository
     ├─ FSEventsMonitor → FileRepository
     ├─ DuplicateFinder → FileRepository + FileHasher
     ├─ StaleFinder → FileRepository
     ├─ CacheDetector → FileRepository
     └─ CSVExporter (static, called from exportCSV())
```

## Recent Learnings
- 2026-02-09: Data caching pattern — lift view data into AppState @Published properties, views read computed props, loadXxx() no-ops if cached, invalidateCache() nils everything
- 2026-02-09: SourceKit cross-file diagnostics are noise during editing — trust xcodebuild
- 2026-02-09: Always re-read files before editing — linter may modify between reads
- 2026-02-09: CSV export — CSVExporter static enum pattern, NSSavePanel for file save, allFiles(forSession:) for bulk fetch
- 2026-02-09: View computed properties from AppState are read-only — assign to appState.xxx directly, not the local computed bridge
- 2026-02-09: .foregroundColor vs .foregroundStyle — use the latter for ShapeStyle values like .tertiary
- 2026-02-09: SwiftUI .task only fires once — views that depend on scan completion need .onChange(of: scanState) to reload after scan finishes
