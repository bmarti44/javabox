#!/usr/bin/env bash
# build-jdk-modules.sh — Create a minimal JDK image for WASM using jlink
#
# Uses the host JDK (macOS or Linux) to run jlink. The resulting JDK image
# contains platform-specific bytecode classes matching the host OS, which
# must be compatible with the native libraries compiled into the WASM binary.
#
# Our native code (libnio.a, libjava.a, etc.) is compiled from OpenJDK's
# unix/ + emscripten/ sources. The macOS JDK bytecode is compatible because
# macOS FileDispatcherImpl doesn't require Linux-specific native methods
# (e.g. init0 for copy_file_range). The TerminalRenderer has been fixed to
# avoid triggering macOS-specific GraphicsEnvironment initialization.
#
# Usage:
#   ./build/build-jdk-modules.sh [output-dir]
#   Example: ./build/build-jdk-modules.sh build/jdk-wasm

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/jdk-detect.sh"

OUTPUT_DIR="${1:-$REPO_ROOT/build/jdk-wasm}"

if [ -d "$OUTPUT_DIR/lib/modules" ]; then
  echo "JDK modules already built at $OUTPUT_DIR"
  echo "Delete $OUTPUT_DIR and re-run to rebuild."
  exit 0
fi

# Same module set as container/Dockerfile jlink
MODULES="java.base,java.compiler,java.datatransfer,java.desktop,java.instrument"
MODULES="$MODULES,java.logging,java.management,java.naming,java.net.http"
MODULES="$MODULES,java.prefs,java.rmi,java.scripting,java.security.jgss"
MODULES="$MODULES,java.security.sasl,java.sql,java.sql.rowset,java.xml"
MODULES="$MODULES,java.xml.crypto,jdk.compiler,jdk.crypto.ec,jdk.httpserver"
MODULES="$MODULES,jdk.jshell,jdk.net,jdk.unsupported,jdk.zipfs"

JDK21_HOME="$(javabox_require_jdk "21" JAVABOX_JDK21_HOME \
  "jlink for building the JDK 21 class library")"
JLINK="$JDK21_HOME/bin/jlink"

echo "Creating minimal JDK image using host jlink..."
echo "jlink: $JLINK"
echo "Modules: $MODULES"
echo "Output:  $OUTPUT_DIR"

# Ensure parent directory exists (jlink creates the output directory itself)
mkdir -p "$(dirname "$OUTPUT_DIR")"

$JLINK \
  --add-modules $MODULES \
  --output "$OUTPUT_DIR" \
  --strip-debug \
  --no-man-pages \
  --no-header-files \
  --compress=2

# Remove native binaries that won't work in WASM (real .so/.dylib files)
# but keep the lib/modules jimage which contains the Java class bytecode
echo "Cleaning native binaries..."
find "$OUTPUT_DIR/lib" -name "*.so" -type f -size +0c -exec rm {} \; 2>/dev/null || true
find "$OUTPUT_DIR/lib" -name "*.dylib" -type f -size +0c -exec rm {} \; 2>/dev/null || true
# Remove native executables
find "$OUTPUT_DIR/bin" -type f -exec rm {} \; 2>/dev/null || true

# Create empty placeholder .so files for libraries the JVM expects to find
# These are loaded via our static symbol dispatch table in os_emscripten.cpp
for lib in libjava libzip libnet libnio libjimage libawt libawt_headless libjawt libfontmanager; do
  touch "$OUTPUT_DIR/lib/${lib}.so"
done

# Report sizes
echo ""
echo "JDK image created:"
du -sh "$OUTPUT_DIR"
du -sh "$OUTPUT_DIR/lib/modules"

echo ""
echo "Key files for WASM embedding:"
echo "  $OUTPUT_DIR/lib/modules     — Class library (main payload)"
echo "  $OUTPUT_DIR/lib/jvm.cfg     — JVM configuration"
echo "  $OUTPUT_DIR/lib/tzdb.dat    — Timezone database"
echo "  $OUTPUT_DIR/conf/           — Security/policy files"
