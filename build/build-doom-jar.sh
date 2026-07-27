#!/usr/bin/env bash
# build-doom-jar.sh — Compile Doom Java sources on host JDK for WASM embedding
#
# Compiles vanilla-mocha-doom + terminal adapter classes into doom.jar
# Same compilation as Dockerfile but run on the host JDK.
#
# Usage:
#   ./build/build-doom-jar.sh [output-dir]
#   Example: ./build/build-doom-jar.sh ~/javabox-wasm/assets

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/jdk-detect.sh"

OUTPUT_DIR="${1:-$REPO_ROOT/build/doom-assets}"
DOOM_SRC="$REPO_ROOT/container/doom/src"
ADAPTER_SRC="$REPO_ROOT/container/doom/adapter"

mkdir -p "$OUTPUT_DIR"

if [ -f "$OUTPUT_DIR/doom.jar" ]; then
  echo "doom.jar already exists at $OUTPUT_DIR/doom.jar"
  exit 0
fi

# Check for host JDK
HOST_JDK=""
if HOST_JDK="$(javabox_find_jdk "26 25 24 23 22 21" JAVABOX_JDK_HOME)"; then
  JAVAC="$HOST_JDK/bin/javac"
  JAR="$HOST_JDK/bin/jar"
else
  JAVAC="$(command -v javac 2>/dev/null || true)"
  JAR="$(command -v jar 2>/dev/null || true)"
fi

if [ ! -x "$JAVAC" ] || [ ! -x "$JAR" ]; then
  echo "ERROR: javac and jar not found. Set JAVABOX_JDK_HOME to a JDK 21 or newer installation."
  exit 1
fi

# Collect all Java source files
DOOM_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$DOOM_TMP_DIR"' EXIT

echo "Compiling Doom sources..."

# Find all .java files in doom src and adapter
find "$DOOM_SRC" "$ADAPTER_SRC" -name "*.java" > "$DOOM_TMP_DIR/sources.txt"
SRCCOUNT=$(wc -l < "$DOOM_TMP_DIR/sources.txt" | tr -d ' ')
echo "  $SRCCOUNT source files"

# Compile
mkdir -p "$DOOM_TMP_DIR/classes"
"$JAVAC" \
  --release 21 \
  -d "$DOOM_TMP_DIR/classes" \
  -Xlint:none \
  @"$DOOM_TMP_DIR/sources.txt" \
  2>&1 || {
    echo "ERROR: Compilation failed"
    exit 1
  }

# Package into jar
echo "Creating doom.jar..."
"$JAR" cf "$OUTPUT_DIR/doom.jar" -C "$DOOM_TMP_DIR/classes" .

# Copy WAD file if available
WAD_FILE="$REPO_ROOT/container/doom/freedoom1.wad"
if [ -f "$WAD_FILE" ]; then
  cp "$WAD_FILE" "$OUTPUT_DIR/freedoom1.wad"
  echo "Copied freedoom1.wad"
else
  echo "WARNING: $WAD_FILE not found - doom.html will fail to start." >&2
  echo "  curl -sL -o /tmp/freedoom.zip \\" >&2
  echo "    https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip" >&2
  echo "  unzip -j /tmp/freedoom.zip 'freedoom-0.13.0/freedoom1.wad' -d container/doom/" >&2
fi

# Copy doom.cfg if available
DOOM_CFG="$REPO_ROOT/container/doom/doom.cfg"
if [ -f "$DOOM_CFG" ]; then
  cp "$DOOM_CFG" "$OUTPUT_DIR/doom.cfg"
  echo "Copied doom.cfg"
fi

echo ""
echo "Doom assets built:"
ls -lh "$OUTPUT_DIR/"
