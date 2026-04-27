#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# DiskSight — Local Release Install
#
# Builds a Release-configuration .app, re-signs it ad-hoc in a single pass to
# work around the hardened-runtime + ad-hoc Team ID mismatch (which makes
# straight `xcodebuild Release` produce a bundle that crashes on launch with
# "Library not loaded: Sparkle.framework ... different Team IDs"), backs up
# the existing /Applications install, and replaces it.
#
# This is for LOCAL development installs only. For shipping releases use
# scripts/release.sh (Developer ID + notarization + DMG + appcast).
#
# Usage:
#   ./scripts/install-release-local.sh
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DERIVED_DATA="${PROJECT_DIR}/build/DerivedData"
APP_NAME="DiskSight.app"
APP_SRC="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}"
APP_DST="/Applications/${APP_NAME}"
BACKUP_SUFFIX=".backup-$(date +%Y-%m-%d-%H%M%S)"

echo "[install-release-local] Building DiskSight (Release)..."
xcodebuild -scheme DiskSight \
    -destination 'platform=macOS' \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    build 2>&1 | tail -3

if [[ ! -d "$APP_SRC" ]]; then
    echo "[install-release-local] ERROR: Build succeeded but ${APP_SRC} not found"
    exit 1
fi

echo "[install-release-local] Re-signing bundle (single-pass ad-hoc)..."
# Single --force --deep --sign - pass gives the main binary AND every embedded
# framework the same ad-hoc signing identity computed in one invocation. Without
# this, hardened-runtime library validation rejects mismatched ad-hoc identities.
codesign --force --deep --sign - "$APP_SRC"
codesign --verify --verbose=2 "$APP_SRC" 2>&1 | tail -2

echo "[install-release-local] Quitting any running DiskSight..."
osascript -e 'tell application "DiskSight" to quit' 2>/dev/null || true
sleep 2
if pgrep -f "${APP_DST}/Contents/MacOS/DiskSight" >/dev/null; then
    pkill -TERM -f "${APP_DST}/Contents/MacOS/DiskSight" || true
    sleep 2
fi

if [[ -d "$APP_DST" ]]; then
    BACKUP="${APP_DST}${BACKUP_SUFFIX}"
    echo "[install-release-local] Backing up existing install to $BACKUP"
    mv "$APP_DST" "$BACKUP"
fi

echo "[install-release-local] Installing to $APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "[install-release-local] Verifying installed bundle..."
codesign --verify --verbose=2 "$APP_DST" 2>&1 | tail -2

echo "[install-release-local] Done. Launch from /Applications/DiskSight.app."
echo "[install-release-local] Old install backed up at: ${APP_DST}${BACKUP_SUFFIX}"
