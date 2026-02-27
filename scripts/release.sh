#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# DiskSight Release Pipeline
#
# Builds a signed release archive, exports the .app, notarizes it, wraps it
# in a DMG, notarizes the DMG, and regenerates the Sparkle appcast.
#
# Usage:
#   ./scripts/release.sh                 # full pipeline
#   ./scripts/release.sh --skip-notarize # skip notarization (local testing)
#
# Environment:
#   NOTARY_PROFILE  keychain profile for notarytool (default: "DiskSight")
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# -- Configurable defaults --------------------------------------------------
NOTARY_PROFILE="${NOTARY_PROFILE:-DiskSight}"
SKIP_NOTARIZE=false
SCHEME="DiskSight"
CONFIGURATION="Release"
BUILD_DIR="${PROJECT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/DiskSight.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
EXPORT_OPTIONS="${PROJECT_DIR}/ExportOptions.plist"

# -- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()    { printf "${YELLOW}[INFO]${NC}  %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

# -- Argument parsing --------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=true ;;
        *)
            error "Unknown argument: $arg"
            echo "Usage: $0 [--skip-notarize]"
            exit 1
            ;;
    esac
done

# -- Cleanup trap ------------------------------------------------------------
TEMP_FILES=()
cleanup() {
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        if [[ -e "$f" ]]; then
            rm -rf "$f"
        fi
    done
}
trap cleanup EXIT

# -- Preflight checks -------------------------------------------------------
info "Running preflight checks..."

MISSING_TOOLS=()
for tool in xcodebuild xcrun hdiutil; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    error "Missing required tools: ${MISSING_TOOLS[*]}"
    error "Please install Xcode Command Line Tools: xcode-select --install"
    exit 1
fi
success "All required tools found."

if [[ ! -f "$EXPORT_OPTIONS" ]]; then
    error "ExportOptions.plist not found at: $EXPORT_OPTIONS"
    error "Create it with your signing team and method, e.g.:"
    error "  <dict>"
    error "    <key>method</key><string>developer-id</string>"
    error "    <key>teamID</key><string>YOUR_TEAM_ID</string>"
    error "  </dict>"
    exit 1
fi
success "ExportOptions.plist found."

# -- Step 1: Read version from Xcode project --------------------------------
info "Reading version from project.pbxproj..."

PBXPROJ="${PROJECT_DIR}/DiskSight.xcodeproj/project.pbxproj"
if [[ ! -f "$PBXPROJ" ]]; then
    error "project.pbxproj not found at: $PBXPROJ"
    exit 1
fi

VERSION=$(grep -m1 'MARKETING_VERSION' "$PBXPROJ" | sed 's/.*= *\(.*\);/\1/' | tr -d ' "')

if [[ -z "$VERSION" ]]; then
    error "Could not parse MARKETING_VERSION from project.pbxproj"
    exit 1
fi

success "Version: $VERSION"

# -- Step 2: Build release archive -------------------------------------------
info "Building release archive..."

mkdir -p "$BUILD_DIR"

xcodebuild archive \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    -project "${PROJECT_DIR}/DiskSight.xcodeproj" \
    | tail -1

if [[ ! -d "$ARCHIVE_PATH" ]]; then
    error "Archive failed — $ARCHIVE_PATH not found."
    exit 1
fi

success "Archive created at $ARCHIVE_PATH"

# -- Step 3: Export archive to .app -------------------------------------------
info "Exporting archive to .app..."

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_PATH" \
    | tail -1

APP_PATH="${EXPORT_PATH}/DiskSight.app"
if [[ ! -d "$APP_PATH" ]]; then
    error "Export failed — DiskSight.app not found in $EXPORT_PATH"
    exit 1
fi

success "Exported .app to $APP_PATH"

# -- Step 4: Notarize the .app bundle ----------------------------------------
if [[ "$SKIP_NOTARIZE" == true ]]; then
    info "Skipping .app notarization (--skip-notarize)."
else
    info "Notarizing .app bundle..."

    APP_ZIP="${BUILD_DIR}/DiskSight-app.zip"
    TEMP_FILES+=("$APP_ZIP")

    ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"

    xcrun notarytool submit "$APP_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    xcrun stapler staple "$APP_PATH"
    success ".app notarized and stapled."
fi

# -- Step 5: Create DMG -------------------------------------------------------
DMG_NAME="DiskSight-${VERSION}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
DMG_TEMP="${BUILD_DIR}/DiskSight-temp.dmg"
DMG_MOUNT="/Volumes/DiskSight"
TEMP_FILES+=("$DMG_TEMP")

info "Creating DMG: $DMG_NAME..."

# Remove stale mount if present
if [[ -d "$DMG_MOUNT" ]]; then
    hdiutil detach "$DMG_MOUNT" -force 2>/dev/null || true
fi

# Remove old artifacts
rm -f "$DMG_TEMP" "$DMG_PATH"

# Create temporary writable DMG (size estimate: app + headroom)
APP_SIZE_KB=$(du -sk "$APP_PATH" | cut -f1)
DMG_SIZE_KB=$(( APP_SIZE_KB + 20480 )) # +20 MB headroom

hdiutil create \
    -size "${DMG_SIZE_KB}k" \
    -fs HFS+ \
    -volname "DiskSight" \
    "$DMG_TEMP"

# Attach, populate, detach
hdiutil attach "$DMG_TEMP" -mountpoint "$DMG_MOUNT"

cp -R "$APP_PATH" "$DMG_MOUNT/"
ln -s /Applications "$DMG_MOUNT/Applications"

hdiutil detach "$DMG_MOUNT"

# Convert to compressed read-only DMG
hdiutil convert "$DMG_TEMP" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH"

if [[ ! -f "$DMG_PATH" ]]; then
    error "DMG creation failed."
    exit 1
fi

success "DMG created at $DMG_PATH"

# -- Step 6: Notarize the DMG -------------------------------------------------
if [[ "$SKIP_NOTARIZE" == true ]]; then
    info "Skipping DMG notarization (--skip-notarize)."
else
    info "Notarizing DMG..."

    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    xcrun stapler staple "$DMG_PATH"
    success "DMG notarized and stapled."
fi

# -- Step 7: Generate / update appcast.xml ------------------------------------
info "Generating appcast.xml..."

GENERATE_APPCAST=""

# Look for Sparkle's generate_appcast in SourcePackages (artifacts or checkouts)
for candidate in \
    "${BUILD_DIR}/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    "${BUILD_DIR}/SourcePackages/checkouts/Sparkle/bin/generate_appcast" \
    "${BUILD_DIR}/SourcePackages/checkouts/Sparkle/Executables/generate_appcast" \
    "${BUILD_DIR}/SourcePackages/checkouts/Sparkle/.build/release/generate_appcast" \
    "${BUILD_DIR}/SourcePackages/checkouts/Sparkle/.build/debug/generate_appcast"; do
    if [[ -x "$candidate" ]]; then
        GENERATE_APPCAST="$candidate"
        break
    fi
done

# Fallback: check if generate_appcast is on PATH
if [[ -z "$GENERATE_APPCAST" ]] && command -v generate_appcast &>/dev/null; then
    GENERATE_APPCAST="$(command -v generate_appcast)"
fi

if [[ -n "$GENERATE_APPCAST" ]]; then
    # Copy DMG into project root for appcast generation (generate_appcast scans a directory)
    APPCAST_STAGING="${BUILD_DIR}/appcast_staging"
    mkdir -p "$APPCAST_STAGING"
    TEMP_FILES+=("$APPCAST_STAGING")
    cp "$DMG_PATH" "$APPCAST_STAGING/"

    "$GENERATE_APPCAST" "$APPCAST_STAGING" -o "${PROJECT_DIR}/appcast.xml"
    success "appcast.xml updated at ${PROJECT_DIR}/appcast.xml"
else
    info "generate_appcast not found — skipping appcast generation."
    info "Install Sparkle or ensure it is in build/SourcePackages/checkouts/Sparkle."
fi

# -- Summary ------------------------------------------------------------------
echo ""
echo "==========================================="
printf "${GREEN}  DiskSight $VERSION Release Complete${NC}\n"
echo "==========================================="
echo ""
echo "  Archive:   $ARCHIVE_PATH"
echo "  App:       $APP_PATH"
echo "  DMG:       $DMG_PATH"
if [[ -f "${PROJECT_DIR}/appcast.xml" ]]; then
    echo "  Appcast:   ${PROJECT_DIR}/appcast.xml"
fi
echo ""
if [[ "$SKIP_NOTARIZE" == true ]]; then
    printf "  ${YELLOW}Notarization was skipped (--skip-notarize).${NC}\n"
else
    printf "  ${GREEN}All artifacts notarized and stapled.${NC}\n"
fi
echo ""
