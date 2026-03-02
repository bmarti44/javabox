#!/usr/bin/env bash
# build/compile-mini-init.sh — Cross-compile mini-init for x86_64 Linux
#
# mini-init replaces c2w-init (/sbin/init) at rootfs.bin offset 54,853,632.
# In cold boot mode (no vm.state snapshot), the kernel execs /sbin/tini
# which execs /sbin/init (this binary).  This eliminates the 5+ minute
# json.Marshal bottleneck from c2w-init's Go runtime.
#
# Usage:
#   ./build/compile-mini-init.sh [--copy-to DIR]
#
# Prerequisites:
#   ~/.rd/bin/docker (Rancher Desktop)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER="${HOME}/.rd/bin/docker"
SRC="${REPO_ROOT}/container/mini-init.c"
OUT="${REPO_ROOT}/build/mini-init.bin"
COPY_TO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --copy-to) COPY_TO="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ ! -f "${SRC}" ]; then
  echo "ERROR: ${SRC} not found"
  exit 1
fi

if [ ! -x "${DOCKER}" ]; then
  echo "ERROR: ${DOCKER} not found — install Rancher Desktop"
  exit 1
fi

echo "==> Compiling mini-init (x86_64 Linux static, Alpine musl-libc)..."
"${DOCKER}" run --rm \
  --platform linux/amd64 \
  -v "${REPO_ROOT}/container:/src" \
  -v "${REPO_ROOT}/build:/out" \
  alpine:3 \
  sh -c '
    apk add --quiet gcc musl-dev linux-headers 2>/dev/null
    gcc -O2 -static -o /out/mini-init.bin /src/mini-init.c
    strip /out/mini-init.bin
    echo "  compiled: $(du -sh /out/mini-init.bin | cut -f1)"
  '

echo "  mini-init.bin : $(du -sh "${OUT}" | cut -f1)"

if [ -n "${COPY_TO}" ]; then
  cp "${OUT}" "${COPY_TO}/mini-init.bin"
  echo "  copied to: ${COPY_TO}/mini-init.bin"
fi

echo ""
echo "==> Done.  Injected at rootfs.bin+54853632 (/sbin/init slot) by index.html."
