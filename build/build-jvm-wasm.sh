#!/usr/bin/env bash
# build-jvm-wasm.sh — Compile OpenJDK Zero to WebAssembly via Emscripten
#
# This builds libjvm.a and supporting native libraries as WASM bitcode
# using Emscripten's emcc/em++ toolchain with the Zero interpreter.
#
# Prerequisites:
#   - Emscripten SDK (emsdk) activated in PATH
#   - Host JDK 21 for boot JDK
#   - libffi built for Emscripten
#
# Usage:
#   ./build/build-jvm-wasm.sh [--clean]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPENJDK_DIR="$REPO_ROOT/openjdk"
BUILD_DIR="$OPENJDK_DIR/build/emscripten-zero"

# Check prerequisites
check_prereqs() {
  if ! command -v emcc &>/dev/null; then
    echo "ERROR: emcc not found. Install and activate Emscripten SDK:"
    echo "  git clone https://github.com/emscripten-core/emsdk.git"
    echo "  cd emsdk && ./emsdk install latest && ./emsdk activate latest"
    echo "  source emsdk_env.sh"
    exit 1
  fi

  if ! command -v java &>/dev/null; then
    echo "ERROR: java not found. Need a host JDK 21 as boot JDK."
    exit 1
  fi

  echo "Emscripten: $(emcc --version | head -1)"
  echo "Host JDK:   $(java -version 2>&1 | head -1)"
}

# Build libffi for Emscripten if not already built
build_libffi() {
  local LIBFFI_DIR="$REPO_ROOT/third-party/libffi-emscripten"

  if [ -f "$LIBFFI_DIR/lib/libffi.a" ]; then
    echo "libffi already built for Emscripten"
    LIBFFI_PREFIX="$LIBFFI_DIR"
    return
  fi

  echo "Building libffi for Emscripten..."
  mkdir -p "$REPO_ROOT/third-party"

  if [ ! -d "$LIBFFI_DIR" ]; then
    git clone --depth 1 https://github.com/nicknisi/libffi-emscripten.git "$LIBFFI_DIR" || {
      # Fallback: build from upstream libffi with Emscripten
      echo "Cloning upstream libffi..."
      git clone --depth 1 --branch v3.4.6 https://github.com/libffi/libffi.git "$LIBFFI_DIR"
    }
  fi

  cd "$LIBFFI_DIR"

  # Use emconfigure/emmake for cross-compilation
  if [ -f configure ]; then
    emconfigure ./configure \
      --host=wasm32-unknown-emscripten \
      --prefix="$LIBFFI_DIR" \
      --enable-static \
      --disable-shared \
      --disable-docs
    emmake make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu)
    emmake make install
  else
    # Try autoconf first
    autoreconf -i 2>/dev/null || true
    emconfigure ./configure \
      --host=wasm32-unknown-emscripten \
      --prefix="$LIBFFI_DIR" \
      --enable-static \
      --disable-shared \
      --disable-docs
    emmake make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu)
    emmake make install
  fi

  cd "$REPO_ROOT"
  LIBFFI_PREFIX="$LIBFFI_DIR"
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

  # Detect boot JDK
  local BOOT_JDK
  if [ -n "${JAVA_HOME:-}" ]; then
    BOOT_JDK="$JAVA_HOME"
  else
    BOOT_JDK="$(dirname $(dirname $(which java)))"
  fi

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
