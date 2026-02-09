# DiskSight Documentation

## Quick Links

| Document | Description |
|----------|-------------|
| [CLAUDE.md](../CLAUDE.md) | Overview, status, commands |
| [CHANGELOG.md](../CHANGELOG.md) | Version history |

### Rule Files (auto-loaded by Claude Code)

| Document | Scope |
|----------|-------|
| [architecture.md](../.claude/rules/architecture.md) | Always loaded - system patterns, invariants |
| [gotchas.md](../.claude/rules/gotchas.md) | Always loaded - known issues |

### Reference Docs

| Document | Description |
|----------|-------------|
| [setup.md](./setup.md) | Build & environment setup |

## Project Overview

DiskSight is a native macOS application for disk usage visualization and analysis. Built with SwiftUI + GRDB, it provides:

- **Treemap, Sunburst, and Icicle** visualizations with drill-down navigation
- **Duplicate detection** via a 3-stage hash pipeline (size grouping, partial hash, full hash)
- **Stale file detection** with configurable time thresholds
- **Cache detection** with safety-coded cleanup recommendations
- **Real-time monitoring** via FSEvents for live filesystem change tracking

## Architecture Summary

```
DiskSightApp → AppState (central @MainActor ObservableObject)
  ├─ FileRepository (actor) ← Database (SQLite/GRDB singleton)
  ├─ FileScanner → batch directory walking
  ├─ FSEventsMonitor → real-time file change tracking
  ├─ DuplicateFinder → 3-stage hash pipeline
  ├─ StaleFinder → date-based detection
  └─ CacheDetector → pattern-based detection
```

Views read cached data from `AppState` and call `loadXxx()` methods which no-op if data is already loaded.

## Contributing

Run `/documenter` after development sessions to keep documentation current.
