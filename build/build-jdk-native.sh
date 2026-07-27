#!/usr/bin/env bash
# build-jdk-native.sh — Build OpenJDK native libraries to WASM with Emscripten
#
# Uses OpenJDK's static-libs-image target to produce the native archives needed
# by the final WASM link.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

OPENJDK_DIR="$REPO_ROOT/openjdk"
BUILD_DIR="$OPENJDK_DIR/build/emscripten-zero"
OUTPUT_DIR="$REPO_ROOT/build/jdk-native-wasm"
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    *)
      if [ "$OUTPUT_DIR" = "$REPO_ROOT/build/jdk-native-wasm" ]; then
        OUTPUT_DIR="$arg"
      else
        echo "Usage: $0 [output-dir] [--force]" >&2
        exit 1
      fi
      ;;
  esac
done

# ── Source Emscripten SDK ──────────────────────────────────────────────────────
if ! command -v emcc &>/dev/null; then
  if [ -f ~/emsdk/emsdk_env.sh ]; then
    source ~/emsdk/emsdk_env.sh 2>/dev/null
  fi
fi

if [ ! -d "$BUILD_DIR" ] || [ ! -f "$BUILD_DIR/spec.gmk" ]; then
  echo "ERROR: OpenJDK is not configured for Emscripten." >&2
  echo "Run build/build-jvm-wasm.sh first to configure openjdk/build/emscripten-zero/." >&2
  exit 1
fi

if ! command -v emcc &>/dev/null; then
  echo "ERROR: emcc not found. Activate the Emscripten SDK and try again." >&2
  exit 1
fi

ARCHIVES=(libjava.a libnio.a libzip.a libjimage.a)

all_archives_are_fresh() {
  local archive
  for archive in "${ARCHIVES[@]}"; do
    if [ ! -f "$OUTPUT_DIR/$archive" ] || [ ! "$OUTPUT_DIR/$archive" -nt "$BUILD_DIR" ]; then
      return 1
    fi
  done
}

echo "=== Building JDK native libraries for WASM ==="
echo "Source: $OPENJDK_DIR"
echo "Output: $OUTPUT_DIR/"
echo ""

# ── Build OpenJDK static libraries ────────────────────────────────────────────
if [ "$FORCE" = false ] && all_archives_are_fresh; then
  echo "JDK native libraries are already up to date. Use --force to rebuild."
else
  JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"
  echo "Building OpenJDK static libraries..."
  (
    cd "$OPENJDK_DIR"
    make CONF=emscripten-zero static-libs-image -j"$JOBS"
  )
fi

# ── Locate and copy static libraries ──────────────────────────────────────────
# static-libs-image always writes here for this OpenJDK build configuration.
STATIC_LIBS_LIB_DIR="$BUILD_DIR/images/static-libs/lib"
if [ ! -d "$STATIC_LIBS_LIB_DIR" ]; then
  STATIC_LIBS_LIB_DIR="$(
    find "$BUILD_DIR/images" -type d -path '*/static-libs/lib' -print -quit 2>/dev/null || true
  )"
fi

if [ ! -d "$STATIC_LIBS_LIB_DIR" ]; then
  echo "ERROR: OpenJDK static-libs image directory not found." >&2
  echo "Expected: $BUILD_DIR/images/static-libs/lib" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
missing=()
for archive in "${ARCHIVES[@]}"; do
  if [ -f "$STATIC_LIBS_LIB_DIR/$archive" ]; then
    cp "$STATIC_LIBS_LIB_DIR/$archive" "$OUTPUT_DIR/$archive"
  else
    missing+=("$archive")
  fi
done

if [ "${#missing[@]}" -ne 0 ]; then
  echo "ERROR: Missing JDK native libraries in $OUTPUT_DIR/: ${missing[*]:-}" >&2
  exit 1
fi

echo ""
echo "=== JDK native libraries built ==="
ls -lh "$OUTPUT_DIR"/*.a
