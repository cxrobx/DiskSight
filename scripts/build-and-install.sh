#!/usr/bin/env bash
set -euo pipefail

# Quick debug build + install to /Applications (for post-push hook)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DERIVED_DATA="${PROJECT_DIR}/build/DerivedData"
APP_NAME="DiskSight.app"
APP_SRC="${DERIVED_DATA}/Build/Products/Debug/${APP_NAME}"
APP_DST="/Applications/${APP_NAME}"

echo "[build-and-install] Building DiskSight (Debug)..."

xcodebuild -scheme DiskSight \
    -destination 'platform=macOS' \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    build 2>&1 | tail -3

if [[ ! -d "$APP_SRC" ]]; then
    echo "[build-and-install] ERROR: Build succeeded but ${APP_SRC} not found"
    exit 1
fi

# Kill running instance if any, then replace
killall DiskSight 2>/dev/null || true
sleep 0.5

rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "[build-and-install] Installed to ${APP_DST}"

# Relaunch
open "$APP_DST"
echo "[build-and-install] Relaunched DiskSight"
