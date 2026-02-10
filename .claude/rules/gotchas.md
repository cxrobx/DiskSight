# Known Gotchas

26 items. **By category**: DB (1,6,7,18,23), Build (2,3,12,13), Frontend (4,9,10,20,21,25), Scanner (5), Arch (8,11,14-17,19,22,24,26)

---

## Database

### 1. GRDB 7.x Insert Returns nil ID
`ScanSession.id` nil after insert — use `db.lastInsertedRowID` fallback.

### 6. Single-Pass Directory Sizes Are Wrong
Fix: multi-pass bottom-up propagation (up to 30 passes).

### 7. ScanSession.completedAt Nil Check
`loadLastSession` must check `session.completedAt != nil` before setting `.completed` state.

---

## Build

### 2. SourceKit Cross-File Diagnostics Are Noise
Red errors like "Cannot find type 'FileNode' in scope" — ignore, trust `xcodebuild`.

### 3. Linter Modifies Files Between Reads
Always re-read a file immediately before editing. Don't batch reads then edits.

### 12. macOS Icons Don't Auto-Mask Like iOS
Bake rounded rect into image (~80% of 1024, radius ~185px, drop shadow). Generate all sizes 16-1024 with 1x/2x scales.

### 13. xcodebuild Clean After Icon Changes
Xcode caches icon assets aggressively. Run `xcodebuild clean` after replacing icon assets.

---

## Frontend

### 4. ForEach + .position() Breaks Hit Testing
Use `onContinuousHover` + manual rect/arc containment. Use `SpatialTapGesture` for clicks.

### 9. View Computed Properties Are Read-Only
Assign to `appState.property` directly, not computed bridges from AppState.

### 10. .foregroundColor Doesn't Accept ShapeStyle
`.foregroundColor(.tertiary)` fails — use `.foregroundStyle(.tertiary)` for ShapeStyle values.

### 20. isLoading Spinner Flickers on Fast Navigation
Keep old content during drill-down. Only `isLoading` for initial load.

### 21. .onChange(of: nodes.count) Misses Same-Count Navigations
Fix: composite identity `"\(count)|\(firstPath)"` for `.onChange`.

### 25. HSplitView Dynamically Adding Children Fails
SwiftUI never adds second pane if initially `nil`. Fix: always render both slots with placeholder when data unavailable.

---

## Scanner

### 5. .skipsHiddenFiles Hides ~450GB of Data
Remove `.skipsHiddenFiles` from `FileManager.enumerator` to capture dotfiles, /private, caches.

---

## Architecture

### 8. FSEvents Invalidates All Cached View Data
`invalidateCache()` called from FSEvents sink, clears all `@Published` cached data. Views re-load on next `.task`.

### 11. .task Doesn't Re-Fire After Scan Completes
Add `.onChange(of: appState.scanState)` to reload on `.completed` transition. Guard `.task` to skip during active scans.

### 14. FSEvents Event ID Lost on App Quit
`nonisolated saveEventIdSync()` via `MainActor.assumeIsolated`. Called from termination notification, `scenePhase(.background)`, `stopMonitoring()`.

### 15. MustScanSubDirs Flag Requires Full Rescan
`kFSEventStreamEventFlagMustScanSubDirs` → individual paths unreliable. Publish on `rescanSubject` → `triggerQuickRescan()`.

### 16. FSEvents Incremental Updates Leave Dir Sizes Stale
Fix: `updateAncestorSizes(forPaths:)` — collect ancestors, sort deepest-first, re-sum children.

### 17. handleBecameActive + invalidateCache Wipes View Data on Launch
Never `invalidateCache()` from `handleBecameActive()` — `.active` fires on initial launch after `.task`.

### 19. invalidateCache() Must Not Clear Viz Navigation State
`vizCurrentPath`/`vizBreadcrumbs` are UI state — only clear `vizChildNodes`.

---

## Database (continued)

### 18. URL("/") Parent Path Produces "/.." Corruption
`URL("/").deletingLastPathComponent().path` → `"//.."`. Special-case `"/"` to use `nil` parent. `rootNode()` has `parent_path = '/..'` fallback.

### 22. Per-Event Cache Invalidation Causes Beachball on Bulk Ops
Fix: `batchProcessedSubject` fires once after DB batch → single invalidation. `deleteFiles(paths:)` batches in 500-chunks.

### 23. Full-File-Set Queries Must Be Paginated
100k+ files → paginate with 5000/page via `nonDirectoryFiles(forSession:limit:offset:)`. Process each page before loading next. Add composite DB index on query columns.

---

## Architecture (continued)

### 24. AsyncStream Initial Progress Must Be Set Before Async Work
Set progress state on `@MainActor` BEFORE `await`-ing the stream — UI sees stale state until first `yield`.

### 26. Actor Contention Blocks Viz Reads Behind FSEvents Writes
Fix: `nonisolated` concurrent read methods bypass actor via `DatabasePool.read` (thread-safe).

---

## Lifecycle

- **SUPERSEDED**: `## #N: [Title] ~~SUPERSEDED~~`
- **Pruning**: >30 items or >15k chars → prune old SUPERSEDED
- **Numbering**: Permanent, gaps intentional
