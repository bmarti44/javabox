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

  # -DWASM_BIGINT must agree with the -sWASM_BIGINT used by link-direct-wasm.sh.
  # src/wasm32/ffi.c gates its i64 marshalling on that macro: without it the
  # JS trampoline splits every long into two i32s while the linked module
  # actually passes BigInts, and the first JNI call taking or returning a long
  # dies with "Cannot convert a BigInt value to a number".
  (
    cd "$LIBFFI_DIR"
    emconfigure ./configure \
      --host=wasm32-unknown-emscripten \
      --prefix="$LIBFFI_PREFIX" \
      --enable-static \
      --disable-shared \
      --disable-docs \
      CFLAGS="-O2 -DWASM_BIGINT"
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

  # The binutils replacements have to be given as absolute paths. The names
  # alone resolve to the host's llvm-nm/llvm-strip, which cannot read wasm
  # objects, and OpenJDK's build uses nm to extract symbols from the archives.
  local EMSDK_LLVM_BIN
  EMSDK_LLVM_BIN="$(em-config LLVM_ROOT)"

  # --with-conf-name pins the build directory to build/emscripten-zero. Without
  # it the default is <os>-<cpu>-<variants>-<debuglevel>, i.e.
  # emscripten-zero-zero-release, which is not what the other scripts look for.
  bash configure \
    --with-conf-name=emscripten-zero \
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
    --enable-static-build \
    --with-libffi="$LIBFFI_PREFIX" \
    --with-sysroot="$EMSDK_SYSROOT" \
    --with-extra-cflags="-pthread -sUSE_PTHREADS=1 -sSHARED_MEMORY=1 -D__EMSCRIPTEN__" \
    --with-extra-cxxflags="-pthread -sUSE_PTHREADS=1 -sSHARED_MEMORY=1 -D__EMSCRIPTEN__ -fwasm-exceptions" \
    --with-extra-ldflags="-pthread -sERROR_ON_UNDEFINED_SYMBOLS=0" \
    --disable-warnings-as-errors \
    --with-debug-level=release \
    --with-native-debug-symbols=none \
    --disable-precompiled-headers \
    --with-x=no \
    --with-cups=no \
    --with-alsa=no \
    --with-fontconfig=no \
    --with-num-cores=4 \
    CC=emcc CXX=em++ AR=emar \
    NM="$EMSDK_LLVM_BIN/llvm-nm" \
    STRIP="$EMSDK_LLVM_BIN/llvm-strip" \
    OBJCOPY="$EMSDK_LLVM_BIN/llvm-objcopy" \
    OBJDUMP="$EMSDK_LLVM_BIN/llvm-objdump" \
    BUILD_CC=cc BUILD_CXX=c++ \
    2>&1 | tee "$REPO_ROOT/build/configure-emscripten.log"

  echo "Configuration complete. Build dir: $BUILD_DIR"
}

# Build HotSpot (libjvm.a)
build_hotspot() {
  echo "Building HotSpot (libjvm.a) for Emscripten..."
  cd "$OPENJDK_DIR"

  # Build just the JVM static library
  # hotspot-only skips prerequisites, so the hotspot build tools and the
  # java.base include headers have to be made first. OpenJDK's make wrapper
  # rejects -jN and wants JOBS=N.
  local JOBS
  JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
  make CONF=emscripten-zero buildtools-hotspot java.base-copy JOBS="$JOBS" \
    2>&1 | tee "$REPO_ROOT/build/build-hotspot.log"
  make CONF=emscripten-zero hotspot-only JOBS="$JOBS" \
    2>&1 | tee -a "$REPO_ROOT/build/build-hotspot.log"

  echo "HotSpot build complete."

  # Check output. With a static build the archive is installed into the jdk
  # image rather than left in hotspot/variant-zero/libjvm/objs/.
  local LIBJVM="$BUILD_DIR/jdk/lib/zero/libjvm.a"
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
