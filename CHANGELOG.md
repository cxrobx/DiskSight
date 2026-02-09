# Changelog

All notable changes to DiskSight are documented here.

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
