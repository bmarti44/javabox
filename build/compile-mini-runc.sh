#!/usr/bin/env bash
# build/compile-mini-runc.sh — Cross-compile mini-runc for x86_64 Linux
#
# Uses Docker (Rancher Desktop) + Alpine Linux to produce a tiny (~50 KB)
# statically-linked x86_64 ELF binary that replaces the 15 MB Go runc in
# the QEMU VM image.  The result is saved to build/mini-runc.bin and
# encoded as base64 in build/mini-runc.b64 for embedding in JavaScript.
#
# Usage:
#   ./build/compile-mini-runc.sh
#
# Prerequisites:
#   ~/.rd/bin/docker (Rancher Desktop)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER="${HOME}/.rd/bin/docker"
SRC="${REPO_ROOT}/container/mini-runc.c"
OUT="${REPO_ROOT}/build/mini-runc.bin"
B64="${REPO_ROOT}/build/mini-runc.b64"

if [ ! -f "${SRC}" ]; then
  echo "ERROR: ${SRC} not found"
  exit 1
fi

if [ ! -x "${DOCKER}" ]; then
  echo "ERROR: ${DOCKER} not found — install Rancher Desktop"
  exit 1
fi

echo "==> Compiling mini-runc (x86_64 Linux static, Alpine musl-libc)..."
"${DOCKER}" run --rm \
  --platform linux/amd64 \
  -v "${REPO_ROOT}/container:/src" \
  -v "${REPO_ROOT}/build:/out" \
  alpine:3 \
  sh -c '
    apk add --quiet gcc musl-dev 2>/dev/null
    gcc -O2 -static -o /out/mini-runc.bin /src/mini-runc.c
    strip /out/mini-runc.bin
    echo "  compiled: $(du -sh /out/mini-runc.bin | cut -f1)"
  '

echo "==> Encoding as base64..."
base64 < "${OUT}" > "${B64}"
echo "  mini-runc.bin : $(du -sh "${OUT}" | cut -f1)"
echo "  mini-runc.b64 : $(wc -c < "${B64}") chars"

echo ""
echo "==> Done.  The base64 blob is at: build/mini-runc.b64"
echo "    Embed it in index.html as MINI_RUNC_B64 (see patchRuncBinary in index.html)."
echo "    Then reload the page — mini-runc will replace /sbin/runc in rootfs.bin"
echo "    at runtime via the ISO 9660 patcher."
