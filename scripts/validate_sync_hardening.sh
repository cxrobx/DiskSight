#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

pass() {
  echo "[PASS] $*"
}

SCANNER="DiskSight/Services/Scanner/FileScanner.swift"
APPSTATE="DiskSight/App/AppState.swift"
SMART="DiskSight/Services/AI/SmartCleanupService.swift"
CACHE="DiskSight/Services/Analysis/CacheDetector.swift"

# 1) Root parent-path regression guard
if rg -n 'dirPath == "/" && dirPath == rootURL\.path \? nil : dirPath' "$SCANNER" >/dev/null; then
  fail "Root child parent_path fallback to nil reintroduced in $SCANNER"
fi
pass "Root parent_path logic uses real parent paths"

# 2) Symlink policy consistency guard
rg -n '\.isSymbolicLinkKey' "$SCANNER" >/dev/null || fail "Missing symbolic link resource key in scanner"
rg -n 'values\.isSymbolicLink == true' "$SCANNER" >/dev/null || fail "Missing symbolic link skip logic in scanner"
pass "Scanner has explicit symlink handling"

# 3) Smart Cleanup cache seeding guard
rg -n 'CacheDetector\.ensureDefaultPatterns\(repository:' "$SMART" >/dev/null || fail "SmartCleanupService no longer seeds cache patterns"
rg -n 'static func ensureDefaultPatterns\(repository:' "$CACHE" >/dev/null || fail "CacheDetector ensureDefaultPatterns missing"
pass "Smart Cleanup path ensures cache patterns are seeded"

# 4) Sync completion gating guard
rg -n 'syncCompletedSuccessfully\(' "$APPSTATE" >/dev/null || fail "AppState sync completion helper missing"
rg -n 'taskIsCancelled:' "$APPSTATE" >/dev/null || fail "AppState sync completion helper missing task cancellation input"
rg -n 'lastProgress:' "$APPSTATE" >/dev/null || fail "AppState sync completion helper missing completion-state input"
rg -n 'guard syncSuccess else' "$APPSTATE" >/dev/null || fail "AppState no longer gates session freshness on sync success"
pass "Sync completion gating remains in place"

# 5) Compile check
xcodebuild -scheme DiskSight -destination 'platform=macOS' build >/dev/null
pass "Build succeeds"

echo "All sync hardening checks passed."
