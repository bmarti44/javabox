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

OUTPUT_DIR="${1:-$REPO_ROOT/build/doom-assets}"
DOOM_SRC="$REPO_ROOT/container/doom/src"
ADAPTER_SRC="$REPO_ROOT/container/doom/adapter"

mkdir -p "$OUTPUT_DIR"

if [ -f "$OUTPUT_DIR/doom.jar" ]; then
  echo "doom.jar already exists at $OUTPUT_DIR/doom.jar"
  exit 0
fi

# Check for host JDK
JAVAC="${JAVA_HOME:-$(dirname $(dirname $(which java)))}/bin/javac"
JAR="${JAVA_HOME:-$(dirname $(dirname $(which java)))}/bin/jar"

if [ ! -x "$JAVAC" ]; then
  echo "ERROR: javac not found. Set JAVA_HOME to a JDK 21 installation."
  exit 1
fi

# Collect all Java source files
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "Compiling Doom sources..."

# Find all .java files in doom src and adapter
find "$DOOM_SRC" "$ADAPTER_SRC" -name "*.java" > "$TMPDIR/sources.txt"
SRCCOUNT=$(wc -l < "$TMPDIR/sources.txt" | tr -d ' ')
echo "  $SRCCOUNT source files"

# Compile
mkdir -p "$TMPDIR/classes"
"$JAVAC" \
  -source 21 -target 21 \
  -d "$TMPDIR/classes" \
  -Xlint:none \
  @"$TMPDIR/sources.txt" \
  2>&1 || {
    echo "ERROR: Compilation failed"
    exit 1
  }

# Package into jar
echo "Creating doom.jar..."
"$JAR" cf "$OUTPUT_DIR/doom.jar" -C "$TMPDIR/classes" .

# Copy WAD file if available
WAD_FILE="$REPO_ROOT/container/doom/freedoom1.wad"
if [ -f "$WAD_FILE" ]; then
  cp "$WAD_FILE" "$OUTPUT_DIR/freedoom1.wad"
  echo "Copied freedoom1.wad"
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
