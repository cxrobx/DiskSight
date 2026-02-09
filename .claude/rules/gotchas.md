# Known Gotchas

Organized by category. 11 items, condensed format. Original numbering preserved (gaps intentional).

## Index

| # | Issue | Category |
|---|-------|----------|
| 1 | GRDB 7.x insert returns nil ID | Database |
| 2 | SourceKit cross-file diagnostics are noise | Build |
| 3 | Linter modifies files between reads | Build |
| 4 | ForEach + .position() breaks hit testing | Frontend |
| 5 | .skipsHiddenFiles hides ~450GB of data | Scanner |
| 6 | Single-pass directory sizes are wrong | Database |
| 7 | ScanSession.completedAt nil check required | Database |
| 8 | FSEvents invalidates all cached view data | Architecture |
| 9 | View computed properties are read-only | Frontend |
| 10 | .foregroundColor doesn't accept ShapeStyle | Frontend |
| 11 | .task doesn't re-fire after scan completes | Architecture |

Standard categories: Database, Build, Frontend, Scanner, Architecture

---

## Database

### 1. GRDB 7.x Insert Returns nil ID
**Symptom**: `ScanSession.id` is nil after insert, causing crash on force unwrap
**Cause**: GRDB 7.x changed insert behavior; `didInsert` callback may not fire as expected
**Solution**: Use `db.lastInsertedRowID` fallback in `createScanSession`. Remove all force unwraps on session IDs.
**Pattern**: `DiskSight/Services/Storage/FileRepository.swift`

### 6. Single-Pass Directory Sizes Are Wrong
**Symptom**: Directory sizes only reflect immediate children, not recursive contents
**Cause**: Original `calculateDirectorySizes` did one pass summing only direct children
**Solution**: Multi-pass bottom-up propagation (up to 30 passes) in `calculateDirectorySizes`
**Pattern**: `DiskSight/Services/Storage/FileRepository.swift`

### 7. ScanSession.completedAt Nil Check Required
**Symptom**: App shows "Scan Complete" when no scan has actually finished
**Cause**: `loadLastSession` was setting `.completed` state without checking `completedAt`
**Solution**: Only set `.completed` when `session.completedAt != nil`
**Pattern**: `DiskSight/App/AppState.swift:loadLastSession`

---

## Build

### 2. SourceKit Cross-File Diagnostics Are Noise
**Symptom**: Red errors in editor like "Cannot find type 'FileNode' in scope"
**Cause**: SourceKit can't resolve types across files during incremental editing
**Solution**: Ignore SourceKit errors. Trust `xcodebuild` — if it compiles, the types resolve.

### 3. Linter Modifies Files Between Reads
**Symptom**: Edit tool fails with "File has been modified since read"
**Cause**: A linter or formatter auto-modifies Swift files after saves
**Solution**: Always re-read a file immediately before editing it. Don't batch reads then edits.

---

## Frontend

### 9. View Computed Properties Are Read-Only
**Symptom**: Build error "cannot assign to property: 'xxx' is a get-only property"
**Cause**: When state is lifted from local `@State` to AppState, view properties become computed (`var foo: T { appState.foo ?? default }`). Old methods that assigned to these local vars break.
**Solution**: Assign to `appState.property` directly, or call the corresponding `appState.loadXxx()` / `appState.invalidateCache()` methods. Never assign to computed property bridges.
**Pattern**: `DiskSight/Views/Cache/CacheView.swift`, `DiskSight/Views/StaleFiles/StaleFilesView.swift`

### 10. .foregroundColor Doesn't Accept ShapeStyle
**Symptom**: Build error "member 'tertiary' in 'Color?' produces result of type 'some ShapeStyle'"
**Cause**: `.foregroundColor()` expects `Color?`, but `.tertiary` is a `ShapeStyle`, not a `Color`
**Solution**: Use `.foregroundStyle(.tertiary)` instead of `.foregroundColor(.tertiary)`
**Pattern**: `DiskSight/Views/Visualization/TreemapView.swift`

### 4. ForEach + .position() Breaks Hit Testing
**Symptom**: Hover/click detection doesn't work on visualization overlays
**Cause**: SwiftUI's `ForEach` + `.position()` overlay doesn't reliably intercept gestures
**Solution**: Use `onContinuousHover` + manual rect/arc containment checks. Use `SpatialTapGesture` for clicks.
**Pattern**: `DiskSight/Views/Visualization/TreemapView.swift`, `SunburstView.swift`, `IcicleView.swift`

---

## Scanner

### 5. .skipsHiddenFiles Hides ~450GB of Data
**Symptom**: Scan reports much less data than expected (misses dotfiles, /private, caches)
**Cause**: `FileManager.enumerator` with `.skipsHiddenFiles` skips hidden files by default
**Solution**: Remove `.skipsHiddenFiles` option from the enumerator
**Pattern**: `DiskSight/Services/Scanner/FileScanner.swift`

---

## Architecture

### 8. FSEvents Invalidates All Cached View Data
**Symptom**: View data may become stale when filesystem changes occur
**Cause**: FSEvents monitor fires when files are created/modified/deleted
**Solution**: `invalidateCache()` is called from the FSEvents sink, clearing all `@Published` cached data on AppState. Views re-load on next `.task` call.
**Pattern**: `DiskSight/App/AppState.swift:startMonitoring`

### 11. .task Doesn't Re-Fire After Scan Completes
**Symptom**: Visualization tab shows "No Data to Visualize" after a scan completes
**Cause**: SwiftUI `.task` fires once on view appearance. If the view is already visible during scanning, `.task` runs with incomplete data (directories have `size = 0` before `calculateDirectorySizes`). When scan completes, `.task` won't re-fire.
**Solution**: Add `.onChange(of: appState.scanState)` to reload viz data when scan transitions to `.completed`. Also guard `.task` to only load when `scanState == .completed`.
**Pattern**: `DiskSight/Views/Visualization/VisualizationContainer.swift`

---

## Lifecycle Management

- **SUPERSEDED**: When a gotcha is resolved, mark it: `## #N: [Title] ~~SUPERSEDED~~`
- **Merging**: If two gotchas share a root cause, merge and note consolidated numbers
- **Pruning**: When gotchas exceed 30 items or 15k chars, prune SUPERSEDED entries older than 90 days
- **Numbering**: Original numbers are permanent — gaps are intentional. Never renumber.
