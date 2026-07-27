#!/usr/bin/env bash
# build-direct.sh — Orchestrate the full direct WASM build pipeline
#
# Builds OpenJDK Zero → WASM in 5 steps:
#   1. build-jvm-wasm.sh    — Compile OpenJDK HotSpot Zero with Emscripten
#   2. build-jdk-native.sh  — Build OpenJDK native static libraries
#   3. build-jdk-modules.sh — Create JDK class library via jlink
#   4. build-doom-jar.sh    — Compile Doom Java sources (optional)
#   5. link-direct-wasm.sh  — Final emcc link → javabox-direct.js + .wasm + .data
#
# Usage:
#   ./build/build-direct.sh <output-dir> [--with-doom] [--clean] [--release]
#   Example: ./build/build-direct.sh ~/javabox-direct-wasm --with-doom --release

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/jdk-detect.sh"
cd "$REPO_ROOT"

# ── Check prerequisites ───────────────────────────────────────────────────────
if [ ! -f "$REPO_ROOT/openjdk/make/Main.gmk" ] || \
   [ ! -f "$REPO_ROOT/third-party/libffi-emscripten/configure.ac" ]; then
  echo "Submodules not initialized. Run: git submodule update --init --recursive" >&2
  exit 1
fi

if ! command -v emcc &>/dev/null; then
  if [ -f ~/emsdk/emsdk_env.sh ]; then
    source ~/emsdk/emsdk_env.sh 2>/dev/null
  fi
fi
if ! command -v emcc &>/dev/null; then
  echo "ERROR: emcc not found. Activate the Emscripten SDK and try again." >&2
  exit 1
fi

BOOT_JDK="$(javabox_require_jdk "21 20" JAVABOX_BOOT_JDK \
  "boot JDK for compiling OpenJDK 21")"
BOOT_JDK_VERSION="$("$BOOT_JDK/bin/java" -version 2>&1 | sed -n '1p')"
JDK21_HOME="$(javabox_require_jdk "21" JAVABOX_JDK21_HOME \
  "jlink for building the JDK 21 class library")"

if ! command -v javac &>/dev/null; then
  echo "ERROR: javac not found. Install a host JDK 21 or newer and try again." >&2
  exit 1
fi

JAVAC_VERSION="$(javac -version 2>&1)"
JAVAC_MAJOR="$(javabox_jdk_major "$JAVAC_VERSION")"
if [ -z "$JAVAC_MAJOR" ] || [ "$JAVAC_MAJOR" -lt 21 ]; then
  echo "ERROR: Host javac must be version 21 or newer. Found: $JAVAC_VERSION" >&2
  exit 1
fi

EMCC_VERSION="$(emcc --version 2>&1 | sed -n '1p')"

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
echo "Resolved tools:"
echo "  emcc:     $EMCC_VERSION"
echo "  Boot JDK: $BOOT_JDK ($BOOT_JDK_VERSION)"
echo "  JDK 21:   $JDK21_HOME"
echo ""

START_TIME=$(date +%s)

# Step 1: Build OpenJDK Zero for WASM
echo ">>> Step 1/5: Building OpenJDK Zero for WASM..."
if [ "$CLEAN" = true ]; then
  "$SCRIPT_DIR/build-jvm-wasm.sh" --clean
else
  "$SCRIPT_DIR/build-jvm-wasm.sh"
fi
echo ""

# Step 2: Build JDK native libraries
echo ">>> Step 2/5: Building JDK native libraries..."
"$SCRIPT_DIR/build-jdk-native.sh"
echo ""

# Step 3: Create JDK modules
echo ">>> Step 3/5: Creating JDK class library..."
"$SCRIPT_DIR/build-jdk-modules.sh"
echo ""

# Step 4: Build Doom (optional)
if [ "$WITH_DOOM" = true ]; then
  echo ">>> Step 4/5: Building Doom assets..."
  "$SCRIPT_DIR/build-doom-jar.sh"
  echo ""
  DOOM_FLAG="--with-doom"
else
  echo ">>> Step 4/5: Skipping Doom (use --with-doom to include)"
  echo ""
  DOOM_FLAG=""
fi

# Step 5: Final link
echo ">>> Step 5/5: Linking final WASM module..."
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
