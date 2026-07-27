#!/usr/bin/env bash
# build-jdk-native.sh — Build OpenJDK native libraries to WASM with Emscripten
#
# Uses OpenJDK's java.base-static-libs target to produce the native archives
# needed by the final WASM link.

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
    --force) FORCE=true ;;  # accepted for compatibility; make is always run now
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

echo "=== Building JDK native libraries for WASM ==="
echo "Source: $OPENJDK_DIR"
echo "Output: $OUTPUT_DIR/"
echo ""

# ── Build OpenJDK static libraries ────────────────────────────────────────────
# Always invoke make and let it decide what is stale. An mtime shortcut here
# would have to know every source the archives depend on, and getting that wrong
# silently ships an old .o - which is exactly what happened when this script
# compared the copied archives against the build directory's timestamp.
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"
echo "Building OpenJDK static libraries..."
# java.base-static-libs, not static-libs-image: only java.base's natives are
# linked into the WASM module, and the full image target also builds
# java.desktop, which needs an X11 toolkit that does not exist here.
# OpenJDK's make wrapper rejects -jN and wants JOBS=N.
(
  cd "$OPENJDK_DIR"
  make CONF=emscripten-zero java.base-static-libs JOBS="$JOBS"
)

# ── Locate and copy static libraries ──────────────────────────────────────────
# With STATIC_LIBS=true each library is archived next to its objects rather than
# in an image directory.
STATIC_LIBS_LIB_DIR="$BUILD_DIR/support/native/java.base"

mkdir -p "$OUTPUT_DIR"
missing=()
for archive in "${ARCHIVES[@]}"; do
  src="$STATIC_LIBS_LIB_DIR/${archive%.a}/static/$archive"
  if [ -f "$src" ]; then
    cp "$src" "$OUTPUT_DIR/$archive"
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
