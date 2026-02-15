#!/bin/bash
# apply-zh-patches.sh
# Re-applies Traditional Chinese patches after a git pull.
# Idempotent: safe to run multiple times.
#
# Usage: bash apply-zh-patches.sh [patch_directory]
# Default patch directory: ~/VoiceInk-patches

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PATCH_DIR="${1:-$HOME/VoiceInk-patches}"

echo "=== Applying Traditional Chinese patches ==="
echo "Repository: $REPO_DIR"
echo "Patch directory: $PATCH_DIR"

if [ ! -d "$PATCH_DIR" ]; then
    echo "Error: Patch directory not found: $PATCH_DIR"
    exit 1
fi

PATCH_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

for patch_file in "$PATCH_DIR"/*.patch; do
    [ -f "$patch_file" ] || continue
    PATCH_NAME="$(basename "$patch_file")"

    # Check if already applied (reverse-check succeeds means patch is currently applied)
    if git -C "$REPO_DIR" apply --reverse --check "$patch_file" 2>/dev/null; then
        echo "  [SKIP] $PATCH_NAME (already applied)"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    # Check if patch can be applied cleanly
    if git -C "$REPO_DIR" apply --check "$patch_file" 2>/dev/null; then
        git -C "$REPO_DIR" apply "$patch_file"
        echo "  [OK]   $PATCH_NAME applied successfully"
        PATCH_COUNT=$((PATCH_COUNT + 1))
    else
        echo "  [FAIL] $PATCH_NAME cannot be applied (patch drift or conflict)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

echo ""
echo "=== Patch summary: $PATCH_COUNT applied, $SKIP_COUNT skipped, $FAIL_COUNT failed ==="

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "Error: $FAIL_COUNT patch(es) failed to apply. Please update your patch files."
    exit 1
fi

echo "Done."
