#!/usr/bin/env bash
# build/convert.sh — Convert the JavaBox container image to browser-runnable WASM+JS
#
# Two modes:
#
#   arm-mac   Apple Silicon macOS — uses a Colima x86_64 VM to run c2w.
#             Slow (full system emulation), but works locally on Apple Silicon.
#             Only needed when the Dockerfile changes; output is reused otherwise.
#             Requires: colima  (brew install colima)
#
#   linux     Linux x86_64 — uses the native c2w binary directly.
#             Fast. Use this in CI pipelines and on Linux build machines.
#             Requires: c2w v0.8.3 installed at /usr/local/bin/c2w
#               wget -qO- https://github.com/container2wasm/container2wasm/releases/download/v0.8.3/container2wasm-v0.8.3-linux-amd64.tar.gz | tar xz
#               sudo mv c2w c2w-net /usr/local/bin/
#
# Mode is auto-detected from uname, or override with --mode arm-mac|linux.
#
# Usage:
#   ./build/convert.sh [--mode arm-mac|linux] [output-dir]
#
# Output:
#   <output-dir>/out.js              — Emscripten JS loader
#   <output-dir>/out.wasm            — QEMU Wasm binary (emulates x86_64 Linux)
#   <output-dir>/out.data            — Packed container filesystem
#   <output-dir>/c2w-net-proxy.wasm  — In-browser HTTP proxy (browser networking mode)

set -euo pipefail

C2W_VERSION="v0.8.3"
IMAGE_NAME="javabox:latest"
COLIMA_PROFILE="javabox-x86"
C2W_NET_PROXY_URL="https://github.com/container2wasm/container2wasm/releases/download/${C2W_VERSION}/c2w-net-proxy.wasm"
# Custom c2w Dockerfile: replaces Go c2w-init with mini-init (C binary that
# chroots into /oci/rootfs and execs bash). Bash profile prints "=========="
# sentinel so snapshot captures bash-ready state.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
C2W_DOCKERFILE="${SCRIPT_DIR}/c2w-custom.Dockerfile"

# ── Parse arguments ────────────────────────────────────────────────────────────
MODE="auto"
OUTPUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)      MODE="$2"; shift 2 ;;
    --mode=*)    MODE="${1#--mode=}"; shift ;;
    -*)          echo "Unknown flag: $1"; exit 1 ;;
    *)           OUTPUT_DIR="$1"; shift ;;
  esac
done
OUTPUT_DIR="${OUTPUT_DIR:-${HOME}/javabox-wasm}"

# ── Auto-detect mode ───────────────────────────────────────────────────────────
if [ "${MODE}" = "auto" ]; then
  OS="$(uname -s)"
  ARCH="$(uname -m)"
  if [ "${OS}" = "Darwin" ] && [ "${ARCH}" = "arm64" ]; then
    MODE="arm-mac"
  elif [ "${OS}" = "Linux" ] && [ "${ARCH}" = "x86_64" ]; then
    MODE="linux"
  else
    echo "ERROR: Cannot auto-detect conversion mode for ${OS}/${ARCH}."
    echo "  Supported platforms: macOS arm64 (--mode arm-mac), Linux x86_64 (--mode linux)"
    exit 1
  fi
fi

echo "==> JavaBox WASM Conversion"
echo "    mode:       ${MODE}"
echo "    c2w:        ${C2W_VERSION}"
echo "    image:      ${IMAGE_NAME}"
echo "    output dir: ${OUTPUT_DIR}"
echo ""

mkdir -p "${OUTPUT_DIR}"

# ── Mode: arm-mac (Apple Silicon macOS via Colima x86_64 VM) ─────────────────
# Uses full x86_64 system emulation so Go's GC runs natively inside the VM.
# Only needed when container/Dockerfile changes — output artifacts are reused.
convert_arm_mac() {
  if ! command -v colima &>/dev/null; then
    echo "ERROR: colima not found."
    echo "  Install: brew install colima lima-additional-guestagents qemu"
    exit 1
  fi

  if ! command -v docker &>/dev/null && ! command -v "${HOME}/.rd/bin/docker" &>/dev/null; then
    echo "ERROR: docker not found."
    exit 1
  fi
  DOCKER_CMD="$(command -v docker 2>/dev/null || echo "${HOME}/.rd/bin/docker")"

  COLIMA_SOCK="${HOME}/.colima/${COLIMA_PROFILE}/docker.sock"

  # Start the Colima x86_64 VM if not already running
  if ! colima status --profile "${COLIMA_PROFILE}" 2>/dev/null | grep -q "Running"; then
    echo "==> Starting Colima x86_64 VM (profile: ${COLIMA_PROFILE})..."
    echo "    Note: first start takes 2-3 minutes. The VM is reused on subsequent runs."
    colima start \
      --arch x86_64 \
      --cpu 4 \
      --memory 8 \
      --disk 60 \
      --profile "${COLIMA_PROFILE}"
    echo ""
  else
    echo "==> Colima x86_64 VM already running (profile: ${COLIMA_PROFILE})"
  fi

  echo "==> Building ${IMAGE_NAME} inside x86_64 VM..."
  DOCKER_HOST="unix://${COLIMA_SOCK}" \
    "${DOCKER_CMD}" build --platform linux/amd64 \
      -t "${IMAGE_NAME}" \
      "$(dirname "$0")/../container/"

  echo ""
  echo "==> Running c2w conversion inside x86_64 VM..."
  echo "    (Slow — full x86_64 system emulation. Only needed when Dockerfile changes.)"
  # SSH into the Colima VM and run c2w natively (linux/amd64 binary).
  # Colima mounts /Users from macOS into the VM at the same path, so OUTPUT_DIR
  # is accessible inside the VM without any extra volume setup.
  colima ssh --profile "${COLIMA_PROFILE}" -- bash -s <<REMOTE
set -euo pipefail

# Install c2w linux/amd64 binary if not already present in the VM
if ! command -v c2w &>/dev/null; then
  echo "  Installing c2w ${C2W_VERSION} in VM..."
  cd /tmp
  wget -q "https://github.com/container2wasm/container2wasm/releases/download/${C2W_VERSION}/container2wasm-${C2W_VERSION}-linux-amd64.tar.gz" \
    -O c2w.tar.gz
  tar xzf c2w.tar.gz
  sudo mv c2w c2w-net /usr/local/bin/
  rm -f c2w.tar.gz
  echo "  c2w installed: \$(c2w --version 2>&1 || true)"
else
  echo "  c2w already installed: \$(c2w --version 2>&1 || true)"
fi

# Output to a native VM path first — BuildKit's lchown fails on colima's FUSE
# mount of /Users (macOS shared dir doesn't support chown). We then copy the
# result to OUTPUT_DIR over the colima FUSE mount, which works fine for plain copies.
VM_OUT="/tmp/javabox-c2w-out"
rm -rf "\${VM_OUT}" && mkdir -p "\${VM_OUT}"

# ZLIB_VERSION=1.3.2: zlib.net removed 1.3.1 (the c2w v0.8.3 default); 1.3.2 exists
# --dockerfile: use custom Dockerfile with mini-init instead of c2w-init
c2w --to-js --build-arg ZLIB_VERSION=1.3.2 --dockerfile "${C2W_DOCKERFILE}" "${IMAGE_NAME}" "\${VM_OUT}/"

mkdir -p "${OUTPUT_DIR}"
cp -r "\${VM_OUT}/." "${OUTPUT_DIR}/"
echo "  Output copied to ${OUTPUT_DIR}"
REMOTE
}

# ── Mode: linux (native x86_64, fast — for CI pipelines) ──────────────────────
convert_linux() {
  if ! command -v c2w &>/dev/null; then
    echo "ERROR: c2w not found."
    echo "  Install c2w ${C2W_VERSION}:"
    echo "    wget -qO- https://github.com/container2wasm/container2wasm/releases/download/${C2W_VERSION}/container2wasm-${C2W_VERSION}-linux-amd64.tar.gz | tar xz"
    echo "    sudo mv c2w c2w-net /usr/local/bin/"
    exit 1
  fi

  if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found."
    exit 1
  fi

  # Build the container image if not already present
  if ! docker image inspect "${IMAGE_NAME}" &>/dev/null 2>&1; then
    echo "==> Building container image ${IMAGE_NAME}..."
    BUILDKIT_PROGRESS=plain docker build --platform linux/amd64 \
      -t "${IMAGE_NAME}" \
      "$(dirname "$0")/../container/"
  else
    echo "==> Image ${IMAGE_NAME} already present (skipping build)"
    echo "    To rebuild: docker build --platform linux/amd64 -t ${IMAGE_NAME} ./container/"
  fi

  echo "==> Running c2w conversion (native x86_64)..."
  # ZLIB_VERSION=1.3.2: zlib.net removed 1.3.1 (the c2w v0.8.3 default); 1.3.2 exists
  # --dockerfile: use custom Dockerfile with mini-init instead of c2w-init
  c2w --to-js --build-arg ZLIB_VERSION=1.3.2 --dockerfile "${C2W_DOCKERFILE}" "${IMAGE_NAME}" "${OUTPUT_DIR}/"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "${MODE}" in
  arm-mac) convert_arm_mac ;;
  linux)   convert_linux ;;
  *)
    echo "ERROR: Unknown mode '${MODE}'. Use: --mode arm-mac|linux"
    exit 1
    ;;
esac

# ── Download c2w-net-proxy.wasm ───────────────────────────────────────────────
PROXY_WASM="${OUTPUT_DIR}/c2w-net-proxy.wasm"
if [ ! -f "${PROXY_WASM}" ]; then
  echo "==> Downloading c2w-net-proxy.wasm..."
  curl -fsSL -o "${PROXY_WASM}" "${C2W_NET_PROXY_URL}"
else
  echo "==> c2w-net-proxy.wasm already present"
fi

echo ""
echo "==> Conversion complete! Output files:"
du -sh "${OUTPUT_DIR}"/* 2>/dev/null | sort -h
echo ""
echo "==> Next steps:"
echo "    1. Compress:  ./build/optimize.sh ${OUTPUT_DIR}"
echo "    2. Serve:     python3 '$(dirname "$0")/serve.py' '${OUTPUT_DIR}'"
