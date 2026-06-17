#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# DiskSight — Build (and optionally bundle) the standalone MCP server
#
#   ./scripts/build-mcp.sh            # build release binary, print its path
#   ./scripts/build-mcp.sh --bundle   # also copy + ad-hoc sign into the
#                                      # installed /Applications/DiskSight.app
#                                      # at Contents/Helpers/DiskSightMCP
#
# The MCP server is a separate SwiftPM executable (it links the MCP SDK; the
# app never does). Bundling it inside the .app gives MCP clients a stable path
# to point at.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

APP_PATH="${APP_PATH:-/Applications/DiskSight.app}"
BUNDLE=false
[[ "${1:-}" == "--bundle" ]] && BUNDLE=true

echo "[build-mcp] Building DiskSightMCP (release)…"
swift build -c release --product DiskSightMCP

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="${BIN_DIR}/DiskSightMCP"

if [[ ! -x "$BIN" ]]; then
    echo "[build-mcp] ERROR: built binary not found at $BIN" >&2
    exit 1
fi

echo "[build-mcp] Built: $BIN"

if $BUNDLE; then
    if [[ ! -d "$APP_PATH" ]]; then
        echo "[build-mcp] ERROR: app not found at $APP_PATH (set APP_PATH=...)" >&2
        exit 1
    fi
    HELPERS="${APP_PATH}/Contents/Helpers"
    mkdir -p "$HELPERS"
    cp -f "$BIN" "${HELPERS}/DiskSightMCP"
    # Ad-hoc sign for local use. For a notarized release, sign with your
    # Developer ID + hardened runtime instead.
    codesign --force --sign - "${HELPERS}/DiskSightMCP"
    echo "[build-mcp] Bundled + signed: ${HELPERS}/DiskSightMCP"
    BIN="${HELPERS}/DiskSightMCP"
fi

cat <<EOF

[build-mcp] Done.

Point your MCP client at:
  ${BIN}

Example (Claude Code / Claude Desktop mcpServers entry):
  {
    "mcpServers": {
      "disksight": { "command": "${BIN}" }
    }
  }
EOF
