# Changelog

All notable changes to DiskSight are documented here.

## [1.1.2] - 2026-02-09

### Fixed
- **Visualization tab loads in <1s instead of 30+** — `FileRepository` actor serialization caused viz read queries to queue behind FSEvents write batches. Added 3 `nonisolated` concurrent read methods (`rootNodeConcurrent`, `childrenWithSizesConcurrent`, `directoryChildrenConcurrent`) that bypass actor serialization via `DatabasePool.read` directly. Updated all visualization call paths in AppState, FolderTreeNode, and VisualizationContainer to use concurrent reads.
- **Folder tree sidebar missing on first load** — `HSplitView` only rendered the main chart pane when `rootTreeNode` was nil at initial render, and SwiftUI never added the sidebar pane later. Fixed by always rendering both `HSplitView` children: sidebar wrapped in `Group {}` with a loading placeholder until tree data arrives.

## [1.1.1] - 2026-02-09

### Added
- **Folder tree context menu**: Right-click on folder tree sidebar rows now shows "Copy Path" and "Show in Finder" actions via existing `VisualizationContextMenu` component

## [1.1.0] - 2026-02-09

### Added
- **Smart Cleanup**: Hybrid rule engine + optional Ollama LLM for intelligent file deletion suggestions
  - `FileClassifier` actor with ~50 deterministic `ClassificationRule` structs — pattern-matches path, extension, age against 12 file categories (logs, caches, build artifacts, downloads, etc.)
  - `SmartCleanupService` orchestrator with paginated file loading (5000/page), classification via `AsyncStream`, and cross-analysis signal merging (duplicate/stale/cache)
  - `OllamaClient` actor for optional LLM-enhanced analysis — HTTP client to `localhost:11434`, model discovery with embedding model filtering, graceful degradation when unavailable
  - `CleanupRecommendation` model with 4 confidence levels (safe/caution/risky/keep) and 9 signal types for explaining recommendations
  - Full tab UI (`SmartCleanupView`): Ollama status indicator with LLM toggle and model picker, summary banner with 3-segment size bar, category filter pills, confidence-grouped recommendation cards with signal badges and trash buttons
  - Sidebar entry in "Clean Up" group with `Cmd+6` keyboard shortcut
  - Settings section: LLM toggle, Ollama URL configuration, model name picker, "Test Connection" button
  - Database: `cleanup_recommendations` table (v2 migration) with indexes, composite index on `(scan_session_id, is_directory)` (v3 migration) for query performance
  - FileRepository: 8 new methods for paginated file queries, recommendation CRUD, and summary aggregation

### Fixed
- Actor method returning `AsyncStream` required `let stream = await actor.method()` then `for await in stream` — direct `for await in await actor.method()` did not compile
- `loadSmartCleanup()` was setting empty `[]` instead of leaving `nil`, causing views to show "no results" instead of "not yet analyzed"
- `SmartCleanupService` loaded all cross-analysis data before classification — restructured to classify first, then merge signals
- `staleFiles` query used `minSize: 0` fetching millions of tiny files — changed to 1MB minimum for cleanup relevance
- Embedding models (e.g. `nomic-embed-text`) incorrectly shown in Ollama model picker — filtered by model family
- `nonDirectoryFiles` loaded entire file set into memory before classification — switched to paginated loading (5000/page) with immediate progress reporting
- Added composite DB index `(scan_session_id, is_directory)` via v3 migration to speed up non-directory file queries

## [1.0.9] - 2026-02-09

### Fixed
- **Beachball on bulk filesystem operations** — running `rm -rf` on a large directory (e.g., 43GB) caused the entire app to become unresponsive. Three compounding issues: (1) every individual FSEvent triggered `invalidateCache()` + `refreshVisualizationData()` on the main thread, flooding it with thousands of cache wipes and DB query tasks; (2) `processPendingEvents()` issued N individual `DELETE` queries sequentially; (3) no batch completion signal, so UI tried to refresh per-event instead of per-batch. Fix: (a) `FSEventsMonitor` now publishes a `batchProcessedSubject` that fires once after an entire debounced batch is processed in the DB, with paths classified into upserts vs deletes upfront; (b) `FileRepository.deleteFiles(paths:)` batches deletes via `DELETE WHERE path IN (...)` in chunks of 500; (c) `AppState` splits FSEvents into two subscribers — `eventCancellable` collects events in 2-second windows for the UI event log only (no cache invalidation), while `batchCancellable` subscribes to `batchProcessedSubject` for a single `invalidateCache()` + `refreshVisualizationData()` + `dataVersion` increment per batch.
- **Folder tree sidebar not refreshing after FSEvents** — after bulk deletion, the treemap chart updated but the folder tree sidebar still showed stale sizes. `FolderTreeNode` objects held immutable `FileNode` snapshots that were never refreshed. Fix: added `@Published var dataVersion: Int` to AppState (incremented in batch processed sink), and `.onChange(of: appState.dataVersion)` in `VisualizationContainer` that rebuilds the tree via `initTreeRoot()` + `syncTreeToCurrentPath()` to preserve the user's navigation position.

### Added
- `FileRepository.deleteFiles(paths:)` — batch delete method using chunked `DELETE WHERE path IN (...)`
- `FileRepository` nonisolated concurrent read methods (`rootNodeConcurrent`, `childrenWithSizesConcurrent`, `directoryChildrenConcurrent`) — bypass actor serialization for read-only queries, preventing visualization reads from blocking behind FSEvents write batches
- `FSEventsMonitor.batchProcessedSubject` — Combine subject that fires once after a complete debounced batch is processed in the database

## [1.0.8] - 2026-02-09

### Fixed
- **Visualization flickering when navigating between folders** — every drill-down, breadcrumb click, and root button press set `isLoading = true`, replacing the chart with a ProgressView spinner for one frame before the new data arrived. Combined with explicit `vizChildNodes = []` clearing before reload, this created two visible blank frames per navigation. Fix: (a) removed `isLoading` toggling from all navigation paths — only the initial `.task` load uses isLoading now; (b) `vizNavigateToRoot()` no longer clears `vizChildNodes` before calling `loadVisualizationRoot()`, letting data replace atomically; (c) changed `.onChange(of: nodes.count)` to `.onChange(of: nodesIdentity)` using composite identity `"\(count)|\(firstPath)"` in all three viz views (Treemap, Sunburst, Icicle) — count alone missed same-count folder navigations, leaving stale hover/click hit areas.

## [1.0.7] - 2026-02-09

### Fixed
- **Tree selection disappears after ~1 second** — clicking folders in the visualization tree sidebar would briefly highlight then reset. Root cause: `invalidateCache()` treated viz navigation state (`vizCurrentPath`, `vizBreadcrumbs`) as cached data, so every FSEvents fire wiped the user's drill-down position. Since `.task` only fires once, nothing reloaded. Fix: (a) `invalidateCache()` no longer clears `vizCurrentPath` or `vizBreadcrumbs` (navigation state, not cached data); (b) `loadVisualizationRoot()` now respects existing `vizCurrentPath` and fetches children for that path instead of always resetting to root; (c) `VisualizationContainer` adds `.onChange(of: childNodes.isEmpty)` to auto-reload when FSEvents empties `vizChildNodes`, keeping tree root intact so expanded folders aren't collapsed.

## [1.0.6] - 2026-02-09

### Fixed
- **Visualizations broken after app launch** — `handleBecameActive()` called `invalidateCache()` on every `scenePhase → .active` transition (including initial launch), wiping all cached view data after `.task` had already fired. Views never reloaded because `.task` only fires once. Fix: removed `invalidateCache()` from `handleBecameActive()`; FSEvents sink already handles real filesystem changes.
- **Root node query fragile** — `rootNode()` queried only `parent_path IS NULL` but FSEvents could overwrite root node's `parent_path` to `"//.."` via `URL("/").deletingLastPathComponent().path`. Fix: added fallback query for `parent_path = '/..'` when primary query returns nil.
- **FSEvents root path edge case** — `URL("/").deletingLastPathComponent().path` produces `"//.."`, corrupting root node's `parent_path` in database. Fix: special-cased path `"/"` in FSEventsMonitor to use `nil` parent instead of computing via URL.

## [1.0.5] - 2026-02-09

### Fixed
- **FSEvents event ID lost on quit** — `stopMonitoring()` used fire-and-forget `Task` that could exit before saving. Now uses synchronous `updateEventIdSync()` + `willTerminateNotification` observer + `scenePhase` background handler
- **Stale event ID after long app closure** — if scan completed >7 days ago, FSEvents journal may have expired. App now detects staleness and triggers automatic rescan instead of replaying from invalid event ID
- **`MustScanSubDirs` flag ignored** — when macOS can't guarantee file-level events, the app now detects this flag and triggers a full rescan via new `rescanSubject` on `FSEventsMonitor`
- **Directory sizes stale after incremental updates** — FSEvents upserts/deletes updated individual files but parent directory sizes were never recalculated. New `updateAncestorSizes(forPaths:)` walks from changed files to root, re-summing at each level
- **No app lifecycle handling** — added `scenePhase` observer in `DiskSightApp`: background saves event ID, active restarts dead monitor streams
- **Event ID also persisted on each debounced event batch** — crash recovery now loses at most the last 2-second window instead of all events since launch

## [1.0.4] - 2026-02-09

### Added
- **App Icon**: Custom icon with color wheel, magnifying glass, and storage device artwork
  - Source kept as `icon_source_1024.png` in repo root
  - All required sizes generated: 16, 32, 64, 128, 256, 512, 1024 with 1x/2x scales
  - macOS icons must include their own rounded rectangle shape (no auto-masking like iOS)
- **Folder Tree Sidebar**: Navigable folder tree alongside visualizations
  - `FolderTreeNode` (`@MainActor ObservableObject`) with lazy child loading and `expandTo()` for path-based tree walking
  - `FolderTreeSidebar` with `DisclosureGroup`-based folder browser, selection highlighting, auto-scroll
  - Integrated into `VisualizationContainer` via `HSplitView` with bidirectional sync (tree selection drives chart drill-down and vice versa)
  - `FileRepository.rootNode()` and `directoryChildren()` queries added

## [1.0.3] - 2026-02-09

### Fixed
- Visualization tab showing "No Data to Visualize" after scan completes — `.task` only fires once on view appearance, so if the view was already visible during scanning it never reloaded. Added `.onChange(of: scanState)` to reload visualization data when scan transitions to `.completed`, and guarded `.task` to skip loading during active scans.

## [1.0.2] - 2026-02-09

### Added
- **Dark Mode Support**: Full dark/light/system appearance toggle
  - `AppearanceMode` enum (System/Light/Dark) persisted via `@AppStorage("appearanceMode")`
  - `.preferredColorScheme()` applied at app root (`DiskSightApp.swift`)
  - Tooltip styling switched from hardcoded colors to `.ultraThinMaterial` background with semantic `.primary`/`.secondary`/`.tertiary` text
  - Canvas strokes adapt via `@Environment(\.colorScheme)`: white strokes in dark mode, black strokes in light mode
  - Appearance picker added to Settings panel
- **CSV Export**: Export scan data as CSV with all file paths, sizes, timestamps
  - `CSVExporter` utility at `Services/Export/CSVExporter.swift` with proper CSV escaping and ISO 8601 timestamps
  - `exportCSV()` method on AppState with NSSavePanel integration
  - "Export CSV" button in Overview quick actions (`.borderedProminent` style)
  - File menu "Export as CSV..." command with `Cmd+Shift+E` shortcut
  - `allFiles(forSession:)` query on FileRepository for bulk export
- CSV headers: `path, name, size_bytes, size_formatted, is_directory, file_type, modified_at, accessed_at, created_at`

### Fixed
- TreemapView: `.foregroundColor(.tertiary)` → `.foregroundStyle(.tertiary)` (type mismatch)
- CacheView: `detectCaches()` delegated to `appState.loadCacheData()` (was assigning to computed property)
- VisualizationContainer: removed stale `loadRoot()`/`navigateTo()` methods that referenced removed local state

## [1.0.1] - 2026-02-09

### Added
- Data caching across views: overview stats, visualization drill-down state, duplicate results, stale files, and cache data persist across tab switches via AppState
- Cache invalidation on scan start, FSEvents changes, and file trashing

### Changed
- Views read from AppState computed properties instead of local `@State`
- `.task` calls `loadXxx()` methods which no-op if data already loaded
- Stale threshold picker binds directly to `$appState.staleThreshold`
- Visualization breadcrumbs and drill-down position preserved across tab switches

### Infrastructure
- Created compound documentation infrastructure (`.claude/agents/`, `.claude/rules/`, `docs/`)

## [1.0.0] - 2025-02-09

### Added
- **Phase 1**: Project scaffold with SQLite/GRDB data layer, FileScanner with async directory walking, FileRepository actor, Full Disk Access entitlement
- **Phase 2**: Overview dashboard with disk usage ring chart, top folders bar chart, squarified treemap visualization with drill-down and hover tooltips
- **Phase 3**: Sunburst and Icicle visualization modes with segmented control switcher, consistent drill-down/breadcrumb across all 3 modes
- **Phase 4**: Duplicate detection via 3-stage pipeline (size grouping, partial xxHash, full xxHash), group cards with Keep Newest / Trash All But First actions
- **Phase 5**: Stale file detection with configurable thresholds (6mo/1yr/2yr/5yr), cache detection with 10 pre-seeded patterns and safety-coded cards
- **Phase 6**: FSEvents real-time monitoring with native C API bridging, 2s debounce, event ID persistence for resume across launches
- **Phase 7**: Keyboard shortcuts, onboarding flow, settings panel, file search, type-specific icons, CSV export

### Fixed
- Session ID crash from GRDB 7.x insert returning nil (use `lastInsertedRowID` fallback)
- Scanner resilience: per-file `try?` prevents one unreadable file from aborting entire scan
- Session state: only show "Scan Complete" when `completedAt` is non-nil
- Recursive directory sizes: multi-pass bottom-up propagation (up to 30 passes)
- Visualization hit testing: replaced broken ForEach+position overlay with manual coordinate checks
- Hidden files scanning: removed `.skipsHiddenFiles` to capture ~450GB of hidden data
