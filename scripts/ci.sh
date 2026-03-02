#!/usr/bin/env bash
# scripts/ci.sh — GitHub Actions CI build pipeline for JavaBox
#
# Runs all build steps in sequence. Intended for CI but also useful locally.
#
# Usage: ./scripts/ci.sh
#
# Requires:
#   - nerdctl (Rancher Desktop) or docker
#   - Node.js 18+
#   - brotli (optional, for optimization step)

set -euo pipefail

# Detect container runtime (prefer nerdctl for Rancher Desktop)
CONTAINER_CMD="nerdctl"
if ! command -v nerdctl &>/dev/null; then
  if command -v docker &>/dev/null; then
    CONTAINER_CMD="docker"
    echo "Warning: nerdctl not found, falling back to docker"
  else
    echo "ERROR: Neither nerdctl nor docker found. Install Rancher Desktop."
    exit 1
  fi
fi

echo "==> Container runtime: ${CONTAINER_CMD}"
echo ""

# ── Step 1: Build TypeScript SDK ──────────────────────────────────────────────
echo "==> [1/5] Building TypeScript SDK..."
cd packages/sdk
npm install
npm run type-check
npm run build
cd ../..
echo "    SDK built: packages/sdk/dist/"
echo ""

# ── Step 2: Build container image ─────────────────────────────────────────────
echo "==> [2/5] Building container image..."
BUILDKIT_PROGRESS=plain ${CONTAINER_CMD} build -t javabox:latest ./container/
echo "    Image built: javabox:latest"
echo ""

# ── Step 3: Smoke test the container ──────────────────────────────────────────
echo "==> [3/5] Smoke testing container (javac + java)..."
${CONTAINER_CMD} run --rm javabox:latest bash -c '
  echo "public class CITest { public static void main(String[] a) { System.out.println(\"CI: OK\"); } }" > /tmp/CITest.java
  javac -d /tmp /tmp/CITest.java
  java -cp /tmp CITest
  echo "javac version: $(javac -version 2>&1)"
  echo "java version: $(java -version 2>&1 | head -1)"
'
echo ""

# ── Step 4: Convert to WASM (skipped in CI unless CONVERT=1) ──────────────────
if [ "${CONVERT:-0}" = "1" ]; then
  echo "==> [4/5] Converting container to WASM (this takes several minutes)..."
  ./build/convert.sh /tmp/javabox-ci-out
  echo "    WASM output: /tmp/javabox-ci-out/"
else
  echo "==> [4/5] Skipping WASM conversion (set CONVERT=1 to enable)"
fi
echo ""

# ── Step 5: Lint / type check ─────────────────────────────────────────────────
echo "==> [5/5] Type checking SDK..."
cd packages/sdk && npm run type-check && cd ../..
echo "    Type check passed"
echo ""

echo "==> CI complete! All steps passed."
echo ""
echo "Next steps for a release:"
echo "  1. CONVERT=1 ./scripts/ci.sh"
echo "  2. ./build/optimize.sh /tmp/javabox-ci-out"
echo "  3. CDN_BUCKET=s3://your-bucket/javabox/v0.1.0/ ./build/cdn-upload.sh /tmp/javabox-ci-out"
