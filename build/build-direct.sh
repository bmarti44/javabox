#!/usr/bin/env bash
# build-direct.sh — Orchestrate the full direct WASM build pipeline
#
# Builds OpenJDK Zero → WASM in 4 steps:
#   1. build-jvm-wasm.sh    — Compile OpenJDK HotSpot Zero with Emscripten
#   2. build-jdk-modules.sh — Create JDK class library via jlink
#   3. build-doom-jar.sh    — Compile Doom Java sources (optional)
#   4. link-direct-wasm.sh  — Final emcc link → javabox-direct.js + .wasm + .data
#
# Usage:
#   ./build/build-direct.sh <output-dir> [--with-doom] [--clean] [--release]
#   Example: ./build/build-direct.sh ~/javabox-direct-wasm --with-doom --release

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:?Usage: $0 <output-dir> [--with-doom] [--clean] [--release]}"
shift

WITH_DOOM=false
CLEAN=false
RELEASE=false
for arg in "$@"; do
  case "$arg" in
    --with-doom) WITH_DOOM=true ;;
    --clean) CLEAN=true ;;
    --release) RELEASE=true ;;
  esac
done

echo "=============================================="
echo "  JavaBox Direct WASM Build Pipeline"
echo "=============================================="
echo "Output:    $OUTPUT_DIR"
echo "Doom:      $WITH_DOOM"
echo "Clean:     $CLEAN"
echo "Release:   $RELEASE"
echo ""

START_TIME=$(date +%s)

# Step 1: Build OpenJDK Zero for WASM
echo ">>> Step 1/4: Building OpenJDK Zero for WASM..."
if [ "$CLEAN" = true ]; then
  "$SCRIPT_DIR/build-jvm-wasm.sh" --clean
else
  "$SCRIPT_DIR/build-jvm-wasm.sh"
fi
echo ""

# Step 2: Create JDK modules
echo ">>> Step 2/4: Creating JDK class library..."
"$SCRIPT_DIR/build-jdk-modules.sh"
echo ""

# Step 3: Build Doom (optional)
if [ "$WITH_DOOM" = true ]; then
  echo ">>> Step 3/4: Building Doom assets..."
  "$SCRIPT_DIR/build-doom-jar.sh"
  echo ""
  DOOM_FLAG="--with-doom"
else
  echo ">>> Step 3/4: Skipping Doom (use --with-doom to include)"
  echo ""
  DOOM_FLAG=""
fi

# Step 4: Final link
echo ">>> Step 4/4: Linking final WASM module..."
RELEASE_FLAG=""
[ "$RELEASE" = true ] && RELEASE_FLAG="--release"
"$SCRIPT_DIR/link-direct-wasm.sh" "$OUTPUT_DIR" $DOOM_FLAG $RELEASE_FLAG
echo ""

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo "=============================================="
echo "  Build complete in ${ELAPSED}s"
echo "=============================================="
echo ""
echo "Output files:"
ls -lh "$OUTPUT_DIR/javabox-direct"* 2>/dev/null || echo "  (no output files found)"
echo ""
echo "To serve locally:"
echo "  npx serve $OUTPUT_DIR --config $SCRIPT_DIR/serve-config.json"
echo ""
echo "To test:"
echo "  npx playwright test tests/e2e-debug.spec.js"
