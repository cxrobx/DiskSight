# Architecture Patterns

Tech stack: Swift, SwiftUI (MVVM), macOS 14.0+, SQLite/GRDB 7.8.0, xxHash-Swift 1.1.1, Xcode+SPM, `com.disksight.app`

## Critical Invariants (DO NOT BREAK)

1. **AppState is @MainActor** — all `@Published` properties, views access via `@EnvironmentObject`. Never publish from background threads.
2. **FileRepository is an actor** — all DB access goes through it. Never call GRDB directly.
3. **Database is a singleton** — `Database.shared` owns the pool, migrations on init.
4. **View data cached on AppState** — `loadXxx()` no-ops if data exists, `invalidateCache()` nils everything.
5. **Trash-based deletion only** — `FileManager.trashItem`, never `removeItem`.

## Key Patterns

### Data Caching
- `loadXxx()` no-ops if data exists; `invalidateCache()` nils cached data. **Never** from `handleBecameActive()` (gotcha #17)
- Viz navigation (`vizCurrentPath`, `vizBreadcrumbs`) preserved across invalidation — only `vizChildNodes` cleared (gotcha #19)
- Drill-down state persists across tab switches and FSEvents cycles

### Visualization Views
- Three modes: Treemap, Sunburst, Icicle — all share `VisualizationContainer`
- Mode persisted via `@AppStorage("visualizationMode")`
- Hit testing: `SpatialTapGesture` + manual coordinate checks; hover: `onContinuousHover` + manual containment
- **No loading spinners during navigation** — keep old content visible (gotcha #20)
- **Composite identity for change detection** — `"\(count)|\(firstPath)"` not `.count` (gotcha #21)

### FSEvents Monitoring
- C API `FSEventStreamCreate` with file-level granularity, 2s debounce
- Event ID persisted on `ScanSession` for resume; saved synchronously on quit via `nonisolated updateEventIdSync()`
- Incremental: create/modify → upsert, delete → remove; ancestor sizes recalculated via `updateAncestorSizes(forPaths:)`
- **Batch processing pipeline**: `processPendingEvents()` classifies paths into upserts vs deletes upfront, batches DB operations. `batchProcessedSubject` fires once after the entire batch completes (gotcha #22)
- **Two AppState subscribers**: `eventCancellable` collects raw events in 2s windows for UI log only; `batchCancellable` subscribes to `batchProcessedSubject` for single `invalidateCache()` + refresh per batch
- `MustScanSubDirs` → full rescan via `rescanSubject`; stale event ID (>7 days) → auto rescan
- Root path `"/"` special-cased: `nil` parent (gotcha #18)

### App Lifecycle (scenePhase)
- `.background` → save event ID. `.active` → restart dead monitors only. **Never `invalidateCache()`** (gotcha #17)
- `willTerminateNotification` → belt-and-suspenders event ID save
- Cache invalidation handled exclusively by `batchProcessedSubject` subscriber (gotcha #22)

### Duplicate Detection
- 3-stage pipeline: size grouping → partial xxHash (first+last 8KB) → full xxHash. Cached on `appState.duplicateGroups`

### CSV Export
- `CSVExporter.generate(from:)` static, `AppState.exportCSV()` with `NSSavePanel`. UI: Overview + File menu `Cmd+Shift+E`

### Dark Mode
- `AppearanceMode` persisted via `@AppStorage("appearanceMode")`. Canvas: `@Environment(\.colorScheme)`. Tooltips: `.ultraThinMaterial` + semantic colors

### Folder Tree Sidebar
- `FolderTreeNode` (`@MainActor ObservableObject`) with lazy children via `directoryChildrenConcurrent()`
- Bidirectional sync in `VisualizationContainer` via `HSplitView`: tree selection drives chart, chart drives `expandTo()`
- `rootNode()` resilient query: `parent_path IS NULL` with `parent_path = '/..'` fallback (gotcha #18)
- HSplitView must always render both children (gotcha #25). Context menu reuses `VisualizationContextMenu`
- **dataVersion-driven refresh**: `AppState.dataVersion` incremented on batch completion; `.onChange(of: dataVersion)` rebuilds tree via `initTreeRoot()` + `syncTreeToCurrentPath()` (preserves nav position)

### Smart Cleanup
- **Hybrid**: Tier 1 `FileClassifier` (~50 rules) + Tier 2 optional `OllamaClient` LLM (graceful degradation)
- **Paginated**: 5000 files/page as `AsyncStream`, classify first then merge cross-analysis signals (gotcha #23)
- **OllamaClient**: Actor to `localhost:11434`; filters embedding models; sorts by param size
- **DB**: `cleanup_recommendations` (v2) + composite index `(scan_session_id, is_directory)` (v3)
- **Progress**: Set initial state BEFORE async work (gotcha #24)

### Batch DB Operations
- **Inserts**: `FileScanner` batches 1000 nodes/transaction; per-file `try?` on `resourceValues`
- **Deletes**: `FileRepository.deleteFiles(paths:)` chunks 500 paths per `DELETE WHERE path IN (...)`
- **Concurrent reads**: `nonisolated` methods (`rootNodeConcurrent`, `childrenWithSizesConcurrent`, `directoryChildrenConcurrent`) bypass actor for read-only queries (gotcha #26)
