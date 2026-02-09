# Architecture Patterns

## Tech Stack

| Component | Technology |
|-----------|------------|
| Language | Swift |
| UI Framework | SwiftUI |
| Platform | macOS 14.0+ (Sonoma) |
| Architecture | MVVM |
| Database | SQLite via GRDB.swift 7.8.0 |
| Hashing | xxHash-Swift 1.1.1 |
| Build System | Xcode + SPM |
| Bundle ID | com.disksight.app |

## Service Graph

```
DiskSightApp
 └─ AppState (@MainActor ObservableObject)
     ├─ FileRepository (actor) ← Database (singleton, DatabasePool)
     ├─ FileScanner → FileRepository
     ├─ FSEventsMonitor → FileRepository
     ├─ DuplicateFinder → FileRepository + FileHasher
     ├─ StaleFinder → FileRepository
     ├─ CacheDetector → FileRepository
     └─ CSVExporter (static, called from exportCSV())
```

## Critical Invariants (DO NOT BREAK)

1. **AppState is @MainActor**: All `@Published` properties live on `AppState`. Views access via `@EnvironmentObject`. Never publish from background threads.
   - Pattern: `DiskSight/App/AppState.swift`

2. **FileRepository is an actor**: All database access goes through `FileRepository`. Never call GRDB directly from views or other services.
   - Pattern: `DiskSight/Services/Storage/FileRepository.swift`

3. **Database is a singleton**: `Database.shared` owns the `DatabasePool`. Migrations run on init. Never create a second pool.
   - Pattern: `DiskSight/Services/Storage/Database.swift`

4. **View data is cached on AppState**: Overview stats, visualization nodes/breadcrumbs, duplicates, stale files, and caches are `@Published` on AppState. Views read computed properties, `.task` calls `loadXxx()` which no-ops if data exists. `invalidateCache()` nils everything.
   - Pattern: `DiskSight/App/AppState.swift`

5. **Trash-based deletion only**: All file deletion uses `FileManager.trashItem`. Never use `removeItem` — users expect recoverability.
   - Pattern: `DiskSight/Views/Duplicates/DuplicatesView.swift`

## Key Patterns

### Data Caching
- `@Published var overviewFileCount: Int?` etc. on AppState
- `loadOverviewData()` / `loadVisualizationRoot()` / `loadStaleFiles()` / `loadCacheData()` — skip if data already loaded
- `invalidateCache()` — called on scan start, FSEvents changes, file trashing
- Visualization drill-down state persists across tab switches

### Visualization Views
- Three modes: Treemap, Sunburst, Icicle — all share `VisualizationContainer`
- Mode persisted via `@AppStorage("visualizationMode")`
- Hit testing uses `SpatialTapGesture` + manual coordinate checks (not SwiftUI hit testing)
- Hover uses `onContinuousHover` + manual rect/arc containment
- Shared `VisualizationTooltip` and `VisualizationContextMenu` components

### FSEvents Monitoring
- Native C API via `FSEventStreamCreate` with file-level granularity
- 2-second debounce coalesces rapid filesystem changes
- Event ID persisted on `ScanSession` for resume across launches
- Incremental DB updates: create/modify → upsert, delete → remove

### Duplicate Detection Pipeline
- Stage 1: Group files by size
- Stage 2: Partial hash (first+last 8KB via xxHash)
- Stage 3: Full hash (streaming xxHash)
- Results cached on `appState.duplicateGroups`

### CSV Export
- `CSVExporter.generate(from:)` — static method converting `[FileNode]` → CSV string
- `AppState.exportCSV()` — fetches all files via `FileRepository.allFiles(forSession:)`, generates CSV, presents `NSSavePanel`
- UI entry points: Overview quick actions button + File menu `Cmd+Shift+E`
- Pattern: `DiskSight/Services/Export/CSVExporter.swift`

### Batch Inserts
- `FileScanner` batches 1000 file nodes per transaction for performance
- Per-file `try?` on `resourceValues` so one unreadable file doesn't abort scan
