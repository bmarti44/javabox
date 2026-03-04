#!/usr/bin/env bash
# build-jdk-native.sh — Compile JDK native libraries to WASM with Emscripten
#
# Compiles libjimage, libzip, and libverify (the minimum set needed for JVM boot)
# into static archives (.a) for linking into the final WASM binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPENJDK="$REPO_ROOT/openjdk"
OUTPUT_DIR="${1:-$REPO_ROOT/build/jdk-native-wasm}"

# JDK include paths (use host JDK for headers)
JDK_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
JDK_INC="$JDK_HOME/include"
JDK_INC_PLATFORM="$JDK_INC/darwin"  # headers are cross-platform for our needs

# OpenJDK source include paths
SHARE_INC="$OPENJDK/src/java.base/share/native/include"
UNIX_INC="$OPENJDK/src/java.base/unix/native/include"
LIBJAVA_INC="$OPENJDK/src/java.base/share/native/libjava"
LIBJAVA_UNIX_INC="$OPENJDK/src/java.base/unix/native/libjava"

COMMON_FLAGS="-O2 -pthread -DLINUX -D_GNU_SOURCE -D_REENTRANT"
COMMON_FLAGS="$COMMON_FLAGS -I$JDK_INC -I$JDK_INC_PLATFORM"
COMMON_FLAGS="$COMMON_FLAGS -I$SHARE_INC -I$UNIX_INC"
COMMON_FLAGS="$COMMON_FLAGS -I$LIBJAVA_INC -I$LIBJAVA_UNIX_INC"
# HotSpot headers needed by some JDK native code
COMMON_FLAGS="$COMMON_FLAGS -I$OPENJDK/src/hotspot/share/include"
COMMON_FLAGS="$COMMON_FLAGS -I$OPENJDK/src/hotspot/os/posix/include"

mkdir -p "$OUTPUT_DIR"

echo "=== Building JDK native libraries for WASM ==="
echo "Source: $OPENJDK/src/java.base/"
echo "Output: $OUTPUT_DIR/"
echo ""

################################################################################
# libjimage — reads lib/modules jimage file
################################################################################
echo "--- Building libjimage ---"
JIMAGE_SHARE="$OPENJDK/src/java.base/share/native/libjimage"
JIMAGE_UNIX="$OPENJDK/src/java.base/unix/native/libjimage"

JIMAGE_SRCS=(
  "$JIMAGE_SHARE/jimage.cpp"
  "$JIMAGE_SHARE/imageFile.cpp"
  "$JIMAGE_SHARE/imageDecompressor.cpp"
  "$JIMAGE_SHARE/endian.cpp"
  "$JIMAGE_UNIX/osSupport_unix.cpp"
)
# NativeImageBuffer.cpp is JNI-only, skip for now

JIMAGE_FLAGS="$COMMON_FLAGS -I$JIMAGE_SHARE"
# libjimage uses zlib for decompression — point to system zlib
JIMAGE_FLAGS="$JIMAGE_FLAGS -I$OPENJDK/src/java.base/share/native/libzip/zlib"

JIMAGE_OBJS=()
for src in "${JIMAGE_SRCS[@]}"; do
  obj="$OUTPUT_DIR/$(basename "${src%.*}").o"
  echo "  Compiling $(basename "$src")..."
  em++ $JIMAGE_FLAGS -c "$src" -o "$obj" 2>&1
  JIMAGE_OBJS+=("$obj")
done

emar rcs "$OUTPUT_DIR/libjimage.a" "${JIMAGE_OBJS[@]}"
echo "  -> libjimage.a ($(du -sh "$OUTPUT_DIR/libjimage.a" | cut -f1))"

################################################################################
# libzip — ZIP/JAR file handling
################################################################################
echo ""
echo "--- Building libzip ---"
ZIP_SHARE="$OPENJDK/src/java.base/share/native/libzip"
ZLIB_DIR="$ZIP_SHARE/zlib"

# For HotSpot boot, only zip_util.c is needed (provides ZIP_Open, ZIP_Close,
# ZIP_FindEntry, ZIP_ReadEntry, ZIP_CRC32). The JNI wrapper files (CRC32.c,
# Deflater.c, etc.) need generated headers and are only called from Java.
ZIP_SRCS=(
  "$ZIP_SHARE/zip_util.c"
)

# Also compile bundled zlib (note: adler32 and crc32 are prefixed with z)
ZLIB_SRCS=(
  "$ZLIB_DIR/zadler32.c"
  "$ZLIB_DIR/compress.c"
  "$ZLIB_DIR/zcrc32.c"
  "$ZLIB_DIR/deflate.c"
  "$ZLIB_DIR/gzclose.c"
  "$ZLIB_DIR/gzlib.c"
  "$ZLIB_DIR/gzread.c"
  "$ZLIB_DIR/gzwrite.c"
  "$ZLIB_DIR/infback.c"
  "$ZLIB_DIR/inffast.c"
  "$ZLIB_DIR/inflate.c"
  "$ZLIB_DIR/inftrees.c"
  "$ZLIB_DIR/trees.c"
  "$ZLIB_DIR/uncompr.c"
  "$ZLIB_DIR/zutil.c"
)

ZIP_FLAGS="$COMMON_FLAGS -I$ZIP_SHARE -I$ZLIB_DIR -DUSE_MMAP"

ZIP_OBJS=()
for src in "${ZIP_SRCS[@]}" "${ZLIB_SRCS[@]}"; do
  obj="$OUTPUT_DIR/$(basename "${src%.*}").o"
  echo "  Compiling $(basename "$src")..."
  emcc $ZIP_FLAGS -c "$src" -o "$obj" 2>&1
  ZIP_OBJS+=("$obj")
done

emar rcs "$OUTPUT_DIR/libzip.a" "${ZIP_OBJS[@]}"
echo "  -> libzip.a ($(du -sh "$OUTPUT_DIR/libzip.a" | cut -f1))"

################################################################################
# Report
################################################################################
echo ""
echo "=== JDK native libraries built ==="
ls -lh "$OUTPUT_DIR"/*.a
