#!/usr/bin/env bash
# build/cdn-upload.sh — Upload WASM artifacts to CDN
#
# This is a template script. Configure for your CDN of choice.
# Supported patterns: AWS S3+CloudFront, Cloudflare R2, or generic rsync.
#
# Usage:
#   CDN_BUCKET=s3://my-bucket/javabox/v0.1.0/ ./build/cdn-upload.sh [htdocs-dir]

set -euo pipefail

HTDOCS="${1:-/tmp/javabox-out/htdocs}"
VERSION="${JAVABOX_VERSION:-v0.1.0}"
CDN_BUCKET="${CDN_BUCKET:-}"

if [ -z "${CDN_BUCKET}" ]; then
  echo "ERROR: CDN_BUCKET environment variable not set."
  echo ""
  echo "Examples:"
  echo "  AWS S3:          CDN_BUCKET=s3://my-cdn-bucket/javabox/${VERSION}/"
  echo "  Cloudflare R2:   CDN_BUCKET=s3://my-r2-bucket/javabox/${VERSION}/  (with R2 endpoint)"
  exit 1
fi

echo "==> JavaBox CDN Upload"
echo "    source:  ${HTDOCS}"
echo "    target:  ${CDN_BUCKET}"
echo "    version: ${VERSION}"
echo ""

# Upload with correct Content-Type and Cache-Control headers
# Pre-compressed .br files are served by CDN with Content-Encoding: br

upload_file() {
  local file="$1"
  local content_type="$2"
  local fname
  fname="$(basename "${file}")"

  echo "  Uploading ${fname}..."
  aws s3 cp "${file}" "${CDN_BUCKET}${fname}" \
    --content-type "${content_type}" \
    --cache-control "public, max-age=31536000, immutable" \
    ${AWS_EXTRA_ARGS:-}
}

upload_brotli() {
  local file="$1"      # .br file
  local content_type="$2"
  local base_name
  base_name="$(basename "${file%.br}")"  # strip .br for the S3 key

  echo "  Uploading ${base_name} (brotli pre-compressed)..."
  aws s3 cp "${file}" "${CDN_BUCKET}${base_name}" \
    --content-type "${content_type}" \
    --content-encoding "br" \
    --cache-control "public, max-age=31536000, immutable" \
    ${AWS_EXTRA_ARGS:-}
}

# Upload Brotli-compressed versions where available; fallback to original
for fname in out.wasm out.data c2w-net-proxy.wasm; do
  br="${HTDOCS}/${fname}.br"
  orig="${HTDOCS}/${fname}"
  if [ -f "${br}" ]; then
    upload_brotli "${br}" "application/wasm"
  elif [ -f "${orig}" ]; then
    upload_file "${orig}" "application/wasm"
  fi
done

# Upload JS loader
for fname in out.js; do
  br="${HTDOCS}/${fname}.br"
  orig="${HTDOCS}/${fname}"
  if [ -f "${br}" ]; then
    upload_brotli "${br}" "application/javascript"
  elif [ -f "${orig}" ]; then
    upload_file "${orig}" "application/javascript"
  fi
done

# Upload manifest (uncompressed, short cache)
if [ -f "${HTDOCS}/manifest.json" ]; then
  echo "  Uploading manifest.json..."
  aws s3 cp "${HTDOCS}/manifest.json" "${CDN_BUCKET}manifest.json" \
    --content-type "application/json" \
    --cache-control "public, max-age=300" \
    ${AWS_EXTRA_ARGS:-}
fi

echo ""
echo "==> Upload complete!"
echo "    CDN URL: https://cdn.example.com/javabox/${VERSION}/"
echo ""
echo "Update wasmBaseUrl in your SDK config:"
echo "  JavaContainer.boot({ wasmBaseUrl: 'https://cdn.example.com/javabox/${VERSION}/' })"
