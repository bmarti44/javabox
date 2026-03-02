#!/bin/bash
# deploy-cloudflare.sh — Deploy JavaBox to Cloudflare Worker + R2
#
# Usage:
#   ./build/deploy-cloudflare.sh [wasm-dir]
#
# Prerequisites (one-time):
#   cd /path/to/javabox
#   npm install --userconfig /dev/null wrangler   # bypasses corporate proxy
#   npx --userconfig /dev/null wrangler login      # authenticate in browser
#
# What it does:
#   1. Creates R2 bucket "javabox-assets" (if not exists)
#   2. Uploads all files to R2
#   3. Deploys Worker that serves from R2 with COOP/COEP headers
#   4. Prints the live URL

set -euo pipefail

WASM_DIR="${1:-$HOME/javabox-wasm}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKER_DIR="$SCRIPT_DIR/cloudflare"
R2_BUCKET="javabox-assets"

# Use local wrangler (handles corporate proxy issues)
WRANGLER="npx --userconfig /dev/null wrangler"

# Files to upload (order: small first, large last for progress visibility)
SMALL_FILES=(
  index.html
  arg-module.js
  load.js
  out.js
  xterm.js
  xterm.css
  xterm-pty.js
  qemu-system-x86_64.worker.js
)
LARGE_FILES=(
  c2w-net-proxy.wasm
  qemu-system-x86_64.wasm
  qemu-system-x86_64.data
)

# ── Preflight checks ─────────────────────────────────────────────────────────

if ! $WRANGLER --version &>/dev/null; then
  echo "ERROR: wrangler not found."
  echo "Install with: cd $REPO_DIR && npm install --userconfig /dev/null wrangler"
  echo "Then run: npx --userconfig /dev/null wrangler login"
  exit 1
fi

if [ ! -f "$WASM_DIR/index.html" ]; then
  echo "ERROR: $WASM_DIR/index.html not found."
  echo "Run the WASM conversion first: ./build/convert.sh $WASM_DIR"
  exit 1
fi

echo "==> Source: $WASM_DIR"
echo ""

# ── Step 1: Create R2 bucket ─────────────────────────────────────────────────

echo "==> Creating R2 bucket '$R2_BUCKET'..."
if $WRANGLER r2 bucket list 2>/dev/null | grep -q "$R2_BUCKET"; then
  echo "    Bucket already exists."
else
  $WRANGLER r2 bucket create "$R2_BUCKET" 2>/dev/null || true
  echo "    Created."
fi
echo ""

# ── Step 2: Upload files to R2 ───────────────────────────────────────────────

echo "==> Uploading files to R2..."

content_type() {
  case "${1##*.}" in
    html) echo "text/html" ;;
    js)   echo "application/javascript" ;;
    css)  echo "text/css" ;;
    wasm) echo "application/wasm" ;;
    data) echo "application/octet-stream" ;;
    *)    echo "application/octet-stream" ;;
  esac
}

upload_file() {
  local file="$1"
  local src="$WASM_DIR/$file"
  if [ ! -f "$src" ]; then
    echo "    SKIP $file (not found)"
    return
  fi
  local size
  size=$(stat -f%z "$src" 2>/dev/null || stat -c%s "$src" 2>/dev/null)
  local human
  if [ "$size" -gt 1048576 ]; then
    human="$(( size / 1048576 ))MB"
  else
    human="$(( size / 1024 ))KB"
  fi
  echo "    $file ($human)..."
  $WRANGLER r2 object put "$R2_BUCKET/$file" --file "$src" --content-type "$(content_type "$file")" --remote 2>/dev/null
}

for f in "${SMALL_FILES[@]}"; do
  upload_file "$f"
done

echo ""
echo "    Uploading large files (this may take a minute)..."
for f in "${LARGE_FILES[@]}"; do
  upload_file "$f"
done
echo ""

# ── Step 3: Deploy Worker ────────────────────────────────────────────────────

echo "==> Deploying Cloudflare Worker..."
cd "$WORKER_DIR"
$WRANGLER deploy
cd "$REPO_DIR"
echo ""

# ── Done ──────────────────────────────────────────────────────────────────────

SUBDOMAIN=$($WRANGLER whoami 2>/dev/null | grep -o 'https://[^ ]*workers.dev' | head -1 || echo "")

echo "=========================================="
echo "  JavaBox deployed!"
echo ""
echo "  URL: https://javabox-demo.*.workers.dev"
echo "  (Check wrangler output above for exact URL)"
echo ""
echo "  Useful commands:"
echo "    npx wrangler tail          # live request logs"
echo "    npx wrangler r2 object ls javabox-assets  # list R2 objects"
echo ""
echo "  To redeploy after changes:"
echo "    ./build/deploy-cloudflare.sh"
echo "=========================================="
