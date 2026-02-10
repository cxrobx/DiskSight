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
| `.claude/rules/gotchas.md` | Known issues (26 items) | Always |
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
| `FolderTreeNode` | ObservableObject for tree state | `Views/Visualization/FolderTreeNode.swift` |
| `FolderTreeSidebar` | Folder tree with lazy loading | `Views/Visualization/FolderTreeSidebar.swift` |
| `FileClassifier` | Deterministic rule engine (~50 rules) | `Services/AI/FileClassifier.swift` |
| `SmartCleanupService` | Orchestrator: classify + merge signals | `Services/AI/SmartCleanupService.swift` |
| `OllamaClient` | HTTP client to Ollama LLM API | `Services/AI/OllamaClient.swift` |
| `CleanupRecommendation` | Recommendation model + GRDB record | `Models/CleanupRecommendation.swift` |
| `FileCategory` | Category/confidence/signal enums | `Models/FileCategory.swift` |

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
     ├─ SmartCleanupService → FileClassifier + FileRepository
     │   └─ OllamaClient (optional, localhost:11434)
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
- 2026-02-09: Dark mode — use `@Environment(\.colorScheme)` for adaptive Canvas drawing; use `.ultraThinMaterial` + semantic colors (`.primary`/`.secondary`) instead of hardcoded black/white for tooltips
- 2026-02-09: macOS icons do NOT auto-mask like iOS — must bake rounded rect shape into the icon image itself; `xcodebuild clean` required after icon asset changes to flush cache
- 2026-02-09: Folder tree sidebar — `@MainActor ObservableObject` nodes with lazy child loading; bidirectional sync between tree selection and chart drill-down via HSplitView
- 2026-02-09: FSEvents lifecycle — `nonisolated` sync save via `MainActor.assumeIsolated` for termination handlers; `scenePhase` + `willTerminateNotification` belt-and-suspenders; stale event ID detection (>7 days → auto rescan); `MustScanSubDirs` → full rescan; incremental ancestor dir size updates
- 2026-02-09: Never call `invalidateCache()` from `handleBecameActive()` — `scenePhase` fires `.active` on initial launch after `.task` already ran; FSEvents sink handles real changes
- 2026-02-09: `URL("/").deletingLastPathComponent().path` produces `"//.."` not nil — special-case root path in FSEventsMonitor; make `rootNode()` resilient with fallback query
- 2026-02-09: Viz navigation state (`vizCurrentPath`, `vizBreadcrumbs`) is UI state, not cached data — `invalidateCache()` must preserve it; only `vizChildNodes` gets cleared; `loadVisualizationRoot()` respects existing path; use `.onChange(of: childNodes.isEmpty)` to auto-reload after FSEvents invalidation without resetting navigation
- 2026-02-09: Don't show loading spinners for sub-100ms operations (SQLite queries) — keep old content visible until new data arrives; setting `isLoading = true` during fast navigation creates a visible blank frame between old chart and new chart
- 2026-02-09: `.onChange(of: array.count)` misses navigations where old and new arrays have equal count — use composite identity string like `"\(count)|\(firstElement)"` to detect content changes
- 2026-02-09: FSEvents bulk ops — per-event `invalidateCache()` on main thread causes beachball; fix: `batchProcessedSubject` fires once after DB batch, two separate subscribers (event log vs cache invalidation); `deleteFiles(paths:)` batches DELETEs in chunks of 500; `nonisolated` concurrent read methods on FileRepository bypass actor for read-only queries; `dataVersion` counter drives folder tree sidebar refresh
- 2026-02-09: Smart Cleanup — paginated DB loading (5000/page) essential for full-file-set processing; AsyncStream actor methods need `let stream = await actor.method()` then `for await`; set initial progress BEFORE async work so UI never shows stale state; filter Ollama embedding models from picker; run cross-analysis signal merging AFTER primary classification, not before
- 2026-02-09: Actor contention — FileRepository actor serializes all calls; FSEvents write batches block viz reads for 30s+. Fix: `nonisolated` concurrent read methods (`rootNodeConcurrent`, etc.) bypass actor via `DatabasePool.read` directly. HSplitView must always render both children — wrap conditional sidebar in `Group {}` with placeholder
