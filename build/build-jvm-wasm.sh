#!/usr/bin/env bash
# build-jvm-wasm.sh — Compile OpenJDK Zero to WebAssembly via Emscripten
#
# This builds libjvm.a and supporting native libraries as WASM bitcode
# using Emscripten's emcc/em++ toolchain with the Zero interpreter.
#
# Prerequisites:
#   - Emscripten SDK (emsdk) activated in PATH
#   - A boot JDK 20 or 21 (set JAVABOX_BOOT_JDK to override detection)
#   - libffi built for Emscripten
#
# Usage:
#   ./build/build-jvm-wasm.sh [--clean]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPENJDK_DIR="$REPO_ROOT/openjdk"
BUILD_DIR="$OPENJDK_DIR/build/emscripten-zero"
BOOT_JDK=""
BOOT_JDK_VERSION=""

source "$SCRIPT_DIR/jdk-detect.sh"

# Check prerequisites
check_prereqs() {
  if ! command -v emcc &>/dev/null; then
    echo "ERROR: emcc not found. Install and activate Emscripten SDK:"
    echo "  git clone https://github.com/emscripten-core/emsdk.git"
    echo "  cd emsdk && ./emsdk install latest && ./emsdk activate latest"
    echo "  source emsdk_env.sh"
    exit 1
  fi

  BOOT_JDK="$(javabox_require_jdk "21 20" JAVABOX_BOOT_JDK \
    "boot JDK for compiling OpenJDK 21")"
  BOOT_JDK_VERSION="$("$BOOT_JDK/bin/java" -version 2>&1 | sed -n '1p')"

  echo "Emscripten: $(emcc --version | head -1)"
  echo "Boot JDK:   $BOOT_JDK ($BOOT_JDK_VERSION)"
}

# Build libffi for Emscripten if not already built
build_libffi() {
  local LIBFFI_DIR="$REPO_ROOT/third-party/libffi-emscripten"
  LIBFFI_PREFIX="$LIBFFI_DIR/install"

  if [ -f "$LIBFFI_PREFIX/lib/libffi.a" ]; then
    echo "libffi already built for Emscripten"
    return
  fi

  if [ ! -d "$LIBFFI_DIR" ] || [ ! -f "$LIBFFI_DIR/configure.ac" ]; then
    echo "ERROR: libffi submodule is not initialized." >&2
    echo "Run: git submodule update --init --recursive" >&2
    exit 1
  fi

  echo "Building libffi for Emscripten..."

  # Use emconfigure/emmake for cross-compilation
  if [ ! -f "$LIBFFI_DIR/configure" ]; then
    if ! (cd "$LIBFFI_DIR" && autoreconf -i); then
      echo "ERROR: autoreconf failed while generating the libffi configure script." >&2
      echo "Install the required Autotools packages and retry." >&2
      exit 1
    fi
  fi

  (
    cd "$LIBFFI_DIR"
    emconfigure ./configure \
      --host=wasm32-unknown-emscripten \
      --prefix="$LIBFFI_PREFIX" \
      --enable-static \
      --disable-shared \
      --disable-docs
  )

  local LIBFFI_MAKE_DIR
  if [ -f "$LIBFFI_DIR/wasm32-unknown-emscripten/Makefile" ]; then
    # libffi's multilib top-level make fails at all-configured; build from the host subdirectory.
    LIBFFI_MAKE_DIR="$LIBFFI_DIR/wasm32-unknown-emscripten"
  else
    LIBFFI_MAKE_DIR="$LIBFFI_DIR"
  fi

  (
    cd "$LIBFFI_MAKE_DIR"
    emmake make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu)
    emmake make install
  )

  if [ ! -f "$LIBFFI_PREFIX/lib/libffi.a" ] || [ ! -f "$LIBFFI_PREFIX/include/ffi.h" ]; then
    echo "ERROR: libffi installation is incomplete at $LIBFFI_PREFIX." >&2
    echo "Expected lib/libffi.a and include/ffi.h; inspect the configure and install output above." >&2
    exit 1
  fi

  echo "libffi built successfully at $LIBFFI_PREFIX"
}

# Configure OpenJDK for Emscripten cross-compilation
configure_openjdk() {
  if [ "${1:-}" = "--clean" ] && [ -d "$BUILD_DIR" ]; then
    echo "Cleaning previous build..."
    rm -rf "$BUILD_DIR"
  fi

  if [ -f "$BUILD_DIR/spec.gmk" ]; then
    echo "OpenJDK already configured (use --clean to reconfigure)"
    return
  fi

  echo "Configuring OpenJDK for Emscripten/Zero..."
  cd "$OPENJDK_DIR"

  # Emscripten sysroot
  local EMSDK_SYSROOT
  EMSDK_SYSROOT="$(em-config EMSCRIPTEN_ROOT)/cache/sysroot"

  bash configure \
    --openjdk-target=wasm32-unknown-emscripten \
    --with-boot-jdk="$BOOT_JDK" \
    --with-toolchain-type=clang \
    --with-jvm-variants=zero \
    --with-jvm-features=zero,serialgc,static-build \
    --disable-jvm-feature-g1gc \
    --disable-jvm-feature-parallelgc \
    --disable-jvm-feature-shenandoahgc \
    --disable-jvm-feature-zgc \
    --disable-jvm-feature-epsilongc \
    --disable-jvm-feature-jfr \
    --disable-jvm-feature-jvmci \
    --disable-jvm-feature-dtrace \
    --disable-jvm-feature-compiler1 \
    --disable-jvm-feature-compiler2 \
    --enable-jvm-feature-zero \
    --enable-jvm-feature-serialgc \
    --enable-jvm-feature-static-build \
    --with-libffi="$LIBFFI_PREFIX" \
    --with-sysroot="$EMSDK_SYSROOT" \
    --with-extra-cflags="-pthread -sUSE_PTHREADS=1 -sSHARED_MEMORY=1 -D__EMSCRIPTEN__" \
    --with-extra-cxxflags="-pthread -sUSE_PTHREADS=1 -sSHARED_MEMORY=1 -D__EMSCRIPTEN__ -fwasm-exceptions" \
    --with-extra-ldflags="-pthread" \
    --disable-warnings-as-errors \
    --with-debug-level=release \
    --with-native-debug-symbols=none \
    --disable-precompiled-headers \
    --with-x=no \
    --with-cups=no \
    --with-alsa=no \
    --with-fontconfig=no \
    --with-freetype=no \
    --with-num-cores=4 \
    CC=emcc CXX=em++ AR=emar NM=llvm-nm \
    BUILD_CC=cc BUILD_CXX=c++ \
    2>&1 | tee "$REPO_ROOT/build/configure-emscripten.log"

  echo "Configuration complete. Build dir: $BUILD_DIR"
}

# Build HotSpot (libjvm.a)
build_hotspot() {
  echo "Building HotSpot (libjvm.a) for Emscripten..."
  cd "$OPENJDK_DIR"

  # Build just the JVM static library
  make CONF=emscripten-zero hotspot-only \
    -j$(nproc 2>/dev/null || sysctl -n hw.ncpu) \
    2>&1 | tee "$REPO_ROOT/build/build-hotspot.log"

  echo "HotSpot build complete."

  # Check output
  local LIBJVM="$BUILD_DIR/hotspot/variant-zero/libjvm/objs/libjvm.a"
  if [ -f "$LIBJVM" ]; then
    echo "SUCCESS: libjvm.a built at $LIBJVM"
    ls -lh "$LIBJVM"
  else
    echo "WARNING: libjvm.a not found at expected path. Checking..."
    find "$BUILD_DIR" -name "libjvm.a" -o -name "libjvm.so" 2>/dev/null || true
  fi
}

# Main
main() {
  echo "=== Building OpenJDK Zero for WebAssembly ==="
  echo ""

  check_prereqs
  build_libffi
  configure_openjdk "$@"
  build_hotspot

  echo ""
  echo "=== Build complete ==="
  echo "Next step: Run build/link-direct-wasm.sh to link the final WASM module"
}

main "$@"
