# DiskSight

## Current Phase: COMPLETE (All 7 phases + post-launch fixes)

## Architecture
- **Pattern:** MVVM with SwiftUI
- **Min target:** macOS 14.0 (Sonoma)
- **Dependencies:** GRDB.swift 7.8.0 (SQLite), xxHash-Swift 1.1.1 (hashing)
- **Build:** `xcodebuild -scheme DiskSight -destination 'platform=macOS' build`
- **Bundle ID:** com.disksight.app

## Phase Summary

### Phase 1: Project Scaffold + Data Layer
- Xcode project with SPM deps
- SQLite schema (files, scan_sessions, cache_patterns) via GRDB migrations
- FileScanner with async directory walking, batch inserts (1000/tx)
- FileRepository actor for all DB operations
- Basic SwiftUI NavigationSplitView shell
- Full Disk Access entitlement + runtime check

### Phase 2: Overview Dashboard + Treemap
- Disk usage ring chart (total/used/free)
- Top folders bar chart, scan status card, quick actions
- Squarified treemap algorithm (TreemapLayout)
- SwiftUI Canvas rendering with file-type color coding
- Click-to-drill-down with breadcrumb navigation
- Hover tooltips

### Phase 3: Sunburst + Icicle Visualizations
- SunburstView with concentric ring arcs
- IcicleView with horizontal stacked rectangles
- Segmented control mode switcher (persisted via @AppStorage)
- Consistent drill-down/breadcrumb across all 3 modes

### Phase 4: Duplicate Detection
- 3-stage pipeline: size grouping → partial hash → full hash
- FileHasher with xxHash (partial: first+last 8KB, full: streaming)
- DuplicatesView with group cards, reclaimable space banner
- Per-group actions: Keep Newest, Trash All But First
- Trash-based deletion (safe, reversible)

### Phase 5: Stale Files + Cache Detection
- StaleFinder with configurable thresholds (6mo/1yr/2yr/5yr)
- CacheDetector with 10 pre-seeded patterns (System/Developer/Package Manager)
- Safety-coded cards (green/yellow/red)
- Clean All Safe bulk action
- StaleFilesView with threshold picker

### Phase 6: FSEvents Real-Time Monitoring
- Native C API bridging via FSEventStreamCreate
- File-level event granularity
- Event coalescing with 2s debounce
- Incremental DB updates (create/modify → upsert, delete → remove)
- Event ID persistence for resume across launches
- Auto-start monitoring after scan

### Phase 7: Polish + Distribution
- Keyboard shortcuts (Cmd+1-5 sections, Cmd+F search)
- Onboarding flow with feature overview + Full Disk Access guidance
- Settings panel (viz mode, monitoring, stale threshold)
- File search via LIKE queries
- FileRowView with type-specific icons
- SQL tracing gated behind #if DEBUG
- Code signing entitlements configured

### Post-Launch Fixes
- **Session ID crash fix** — `ScanSession.id` was nil after GRDB 7.x insert; added `db.lastInsertedRowID` fallback in `createScanSession`, removed all force unwraps in AppState
- **Scanner resilience** — Per-file `try?` on `resourceValues` so one unreadable file doesn't abort the entire scan; error logging in catch block
- **Session state fix** — `loadLastSession` only shows "Scan Complete" when `completedAt` is non-nil
- **Recursive directory sizes** — `calculateDirectorySizes` now uses multi-pass bottom-up propagation (up to 30 passes) instead of single-pass immediate-children-only sum
- **Hover hit testing** — Replaced broken `ForEach` + `.position()` overlay with `onContinuousHover` + manual rect/arc containment checks on all 3 visualization views
- **Click hit testing** — Uses `SpatialTapGesture` with coordinate-based hit testing for drill-down
- **Directory color palette** — 12 distinct colors for directories based on name hash; files still use type-based coloring
- **Hidden files scanning** — Removed `.skipsHiddenFiles` to capture ~450GB of previously invisible data (dotfiles, /private, caches)
- **Mouse-following tooltips** — Tooltip tracks cursor position with offset, dark background (black 85% opacity) with white text for high contrast
- **Right-click context menu** — "Copy Path" (clipboard) and "Show in Finder" on all visualization views
- **Shared tooltip/menu** — `VisualizationTooltip` and `VisualizationContextMenu` shared across Treemap, Icicle, Sunburst

## Key Types
- `FileNode` — GRDB record for file metadata
- `ScanSession` — Scan tracking with FSEvents ID
- `DuplicateGroup` — Groups files by content hash
- `CachePattern` — GRDB record for cache detection patterns
- `AppState` — @MainActor ObservableObject, scan/monitor lifecycle
- `FileScanner` — Async directory walker
- `FileRepository` — Actor for all DB operations
- `Database` — Singleton with DatabasePool + migrations
- `FSEventsMonitor` — C API bridge with debounce
- `DuplicateFinder` — 3-stage duplicate pipeline
- `StaleFinder` — Date-based stale file detection
- `CacheDetector` — Pattern-based cache detection
- `FileHasher` — xxHash partial + full hashing
- `TreemapAlgorithm` — Squarified treemap layout
- `SunburstLayout` — Concentric ring layout
- `IcicleLayout` — Stacked rectangle layout

## Service Connections
```
DiskSightApp
 └─ AppState
     ├─ FileRepository ← Database (SQLite/GRDB)
     ├─ FileScanner → FileRepository
     ├─ FSEventsMonitor → FileRepository
     ├─ DuplicateFinder → FileRepository + FileHasher
     ├─ StaleFinder → FileRepository
     └─ CacheDetector → FileRepository
```

## Files
```
DiskSight/
├── App/
│   ├── DiskSightApp.swift
│   └── AppState.swift
├── Models/
│   ├── FileNode.swift
│   ├── ScanSession.swift
│   └── DuplicateGroup.swift
├── Services/
│   ├── Scanner/FileScanner.swift
│   ├── Storage/Database.swift
│   ├── Storage/FileRepository.swift
│   ├── Monitor/FSEventsMonitor.swift
│   ├── Analysis/DuplicateFinder.swift
│   ├── Analysis/StaleFinder.swift
│   ├── Analysis/CacheDetector.swift
│   └── Hashing/FileHasher.swift
├── Views/
│   ├── Sidebar/SidebarView.swift
│   ├── Overview/OverviewView.swift
│   ├── Visualization/
│   │   ├── TreemapLayout.swift
│   │   ├── TreemapView.swift
│   │   ├── SunburstView.swift
│   │   ├── IcicleView.swift
│   │   └── VisualizationContainer.swift
│   ├── Duplicates/DuplicatesView.swift
│   ├── StaleFiles/StaleFilesView.swift
│   ├── Cache/CacheView.swift
│   └── Shared/
│       ├── SizeFormatter.swift
│       ├── FileRowView.swift
│       ├── SearchView.swift
│       ├── SettingsView.swift
│       └── OnboardingView.swift
├── Utilities/Extensions.swift
├── Resources/Assets.xcassets
└── DiskSight.entitlements
```
