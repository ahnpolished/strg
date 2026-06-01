#!/usr/bin/env bash
# mount-test-photos.sh — Add test photos to the iOS simulator's photo library.
#
# Usage:
#   ./apps/ios/scripts/mount-test-photos.sh
#
# This adds a selection of test photos to the booted simulator so you
# can pick them from the app's photo picker.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DATA_DIR="$REPO_ROOT/model/data/test"

# Find the first booted simulator
SIM_UDID=$(xcrun simctl list devices | grep Booted | head -1 | awk -F'[()]' '{print $2}' | tr -d ' ')
if [[ -z "$SIM_UDID" ]]; then
    echo "ERROR: No booted simulator found. Boot one first."
    exit 1
fi

echo "========================================"
echo " strg — Mount Test Photos"
echo "========================================"
echo "Simulator: $SIM_UDID"
echo ""

PHOTOS=(
    "$DATA_DIR/001.jpg"   # synthetic simple
    "$DATA_DIR/002.jpg"   # synthetic simple
    "$DATA_DIR/011.jpeg"  # REAL handwritten photo
    "$DATA_DIR/019.jpg"   # synthetic table layout (18 entries)
    "$DATA_DIR/022.jpeg"  # synthetic
)

for img in "${PHOTOS[@]}"; do
    if [[ -f "$img" ]]; then
        xcrun simctl addmedia "$SIM_UDID" "$img" 2>/dev/null
        echo "  ✅ $(basename "$img")"
    else
        echo "  ❌ $(basename "$img") — not found"
    fi
done

echo ""
echo "✅ Photos added to simulator library."
echo "   Open the app → 'Select Workout Photo' → pick from library"
echo ""
echo "   $(basename "${PHOTOS[2]}") — REAL handwritten workout journal"
