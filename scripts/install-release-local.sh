#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# DiskSight — Local Release Install
#
# Builds a Release .app, bundles the DiskSightMCP helper, signs everything, and
# installs to /Applications (backing up any existing install).
#
# Signing identity (auto-detected):
#   • "Developer ID Application" cert present  → sign with it + hardened runtime.
#     FDA (and any other TCC grant) is keyed to your Team ID, so it SURVIVES
#     every rebuild — no re-granting Full Disk Access after each install.
#   • No Developer ID cert  → ad-hoc fallback (the old behavior). Works, but TCC
#     keys on the cdhash, so FDA must be re-granted after each reinstall.
#
# For shipping releases use scripts/release.sh (Developer ID + notarization +
# DMG + appcast).
#
# Usage:  ./scripts/install-release-local.sh
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DERIVED_DATA="${PROJECT_DIR}/build/DerivedData"
APP_NAME="DiskSight.app"
APP_SRC="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}"
APP_DST="/Applications/${APP_NAME}"
ENTITLEMENTS="${PROJECT_DIR}/DiskSight/DiskSight.entitlements"
BACKUP_SUFFIX=".backup-$(date +%Y-%m-%d-%H%M%S)"

# --- Detect signing identity ------------------------------------------------
DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/^[^"]*"([^"]+)".*/\1/' || true)"

if [[ -n "$DEVID" ]]; then
    TEAMID="$(echo "$DEVID" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')"
    echo "[install-release-local] Signing with: $DEVID"
    echo "[install-release-local] (FDA keyed to Team $TEAMID — survives rebuilds)"
else
    echo "[install-release-local] No Developer ID cert — ad-hoc signing (FDA resets each install)."
fi

# --- Build ------------------------------------------------------------------
echo "[install-release-local] Building DiskSight (Release)..."
if [[ -n "$DEVID" ]]; then
    # Let Xcode sign the app + embedded frameworks (incl. Sparkle's nested code)
    # with the Developer ID during the build — consistent Team ID satisfies
    # hardened-runtime library validation.
    xcodebuild -scheme DiskSight -destination 'platform=macOS' -configuration Release \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$DEVID" DEVELOPMENT_TEAM="$TEAMID" \
        "OTHER_CODE_SIGN_FLAGS=--timestamp=none" \
        build 2>&1 | tail -3
else
    xcodebuild -scheme DiskSight -destination 'platform=macOS' -configuration Release \
        -derivedDataPath "$DERIVED_DATA" build 2>&1 | tail -3
fi

if [[ ! -d "$APP_SRC" ]]; then
    echo "[install-release-local] ERROR: Build succeeded but ${APP_SRC} not found"
    exit 1
fi

# --- Bundle the MCP helper --------------------------------------------------
echo "[install-release-local] Building + bundling DiskSightMCP helper..."
swift build -c release --product DiskSightMCP >/dev/null
HELPER_BIN="$(swift build -c release --show-bin-path)/DiskSightMCP"
mkdir -p "$APP_SRC/Contents/Helpers"
cp -f "$HELPER_BIN" "$APP_SRC/Contents/Helpers/DiskSightMCP"

# --- Sign -------------------------------------------------------------------
echo "[install-release-local] Signing bundle..."
if [[ -n "$DEVID" ]]; then
    # Sign the helper, then re-seal the app (no --deep: the frameworks keep their
    # Xcode-applied Developer ID signatures; this just re-seals resources to
    # include the helper and re-signs the main executable with entitlements).
    codesign --force --options runtime --timestamp=none --sign "$DEVID" \
        "$APP_SRC/Contents/Helpers/DiskSightMCP"
    codesign --force --options runtime --timestamp=none \
        --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$APP_SRC"
else
    # Ad-hoc: one --deep pass gives the app, frameworks, and helper the same
    # ad-hoc identity (hardened-runtime library validation needs them to match).
    codesign --force --deep --sign - "$APP_SRC"
fi
codesign --verify --deep --strict --verbose=2 "$APP_SRC" 2>&1 | tail -2

# --- Install ----------------------------------------------------------------
echo "[install-release-local] Quitting any running DiskSight..."
osascript -e 'tell application "DiskSight" to quit' 2>/dev/null || true
sleep 2
if pgrep -x DiskSight >/dev/null; then pkill -TERM -x DiskSight || true; sleep 2; fi

if [[ -d "$APP_DST" ]]; then
    echo "[install-release-local] Backing up existing install to ${APP_DST}${BACKUP_SUFFIX}"
    mv "$APP_DST" "${APP_DST}${BACKUP_SUFFIX}"
fi

echo "[install-release-local] Installing to $APP_DST"
cp -R "$APP_SRC" "$APP_DST"
# Belt-and-suspenders: a local cp doesn't quarantine, but clear it anyway so an
# unnotarized Developer ID build never trips Gatekeeper on launch.
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true
codesign --verify --verbose=2 "$APP_DST" 2>&1 | tail -2

echo "[install-release-local] Done. Launch from /Applications/DiskSight.app."
echo "[install-release-local] MCP helper: ${APP_DST}/Contents/Helpers/DiskSightMCP"
