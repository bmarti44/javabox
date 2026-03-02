#!/usr/bin/env bash
# build/optimize.sh — Compress WASM output files for efficient browser delivery
#
# Applies Brotli compression (best ratio for WASM) to all large files.
# Browsers that support Brotli (all modern browsers) will receive .br files.
# Your CDN/server must be configured to serve pre-compressed files.
#
# Usage:
#   ./build/optimize.sh [htdocs-dir]
#
# Prerequisites:
#   - brotli CLI: brew install brotli (macOS) / apt install brotli (Linux)

set -euo pipefail

HTDOCS="${1:-/tmp/javabox-out/htdocs}"

echo "==> JavaBox WASM Optimization"
echo "    directory: ${HTDOCS}"
echo ""

# Check brotli is available
if ! command -v brotli &>/dev/null; then
  echo "ERROR: brotli not found."
  echo "  macOS:  brew install brotli"
  echo "  Linux:  apt install brotli  /  yum install brotli"
  exit 1
fi

compress_file() {
  local file="$1"
  local base
  base="$(basename "${file}")"
  local original_size
  original_size="$(du -sh "${file}" | cut -f1)"

  echo -n "  ${base} (${original_size}) → "
  brotli -q 11 -f -o "${file}.br" "${file}"
  local compressed_size
  compressed_size="$(du -sh "${file}.br" | cut -f1)"
  echo "${base}.br (${compressed_size})"
}

echo "==> Compressing with Brotli (quality 11)..."
echo ""

# Compress the main WASM artifacts
for ext in wasm data js; do
  for f in "${HTDOCS}"/*.${ext}; do
    [ -f "${f}" ] && compress_file "${f}"
  done
done


echo ""
echo "==> Summary:"
echo "    Original total: $(du -sh ${HTDOCS} --exclude='*.br' --exclude='*.gz' 2>/dev/null | tail -1 | cut -f1)"
echo "    Compressed .br: $(du -sh ${HTDOCS}/*.br 2>/dev/null | awk '{sum += $1} END {print sum}' || echo 'N/A')"
echo ""

# Generate a manifest with file sizes and checksums
echo "==> Generating manifest.json..."
python3 - <<'PYEOF'
import os, json, hashlib, sys

htdocs = sys.argv[1] if len(sys.argv) > 1 else '/tmp/javabox-out/htdocs'
manifest = {"files": {}}

for fname in sorted(os.listdir(htdocs)):
    fpath = os.path.join(htdocs, fname)
    if os.path.isfile(fpath) and not fname.endswith('.br') and not fname.endswith('.gz'):
        with open(fpath, 'rb') as f:
            data = f.read()
        sha256 = hashlib.sha256(data).hexdigest()
        br_path = fpath + '.br'
        manifest["files"][fname] = {
            "size": len(data),
            "sha256": sha256,
            "brotli_size": os.path.getsize(br_path) if os.path.exists(br_path) else None,
        }

with open(os.path.join(htdocs, 'manifest.json'), 'w') as f:
    json.dump(manifest, f, indent=2)
print("  manifest.json written")
PYEOF
"${HTDOCS}"

echo ""
echo "==> Optimization complete. Files ready for CDN upload."
echo "    Run: ./build/cdn-upload.sh ${HTDOCS}"
