#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: ./build/fetch-prebuilt.sh <output-dir> [--base-url <url>] [--force]" >&2
}

if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
  usage
  exit 1
fi

output_dir=$1
shift

base_url="https://javabox-demo.brian-fec.workers.dev"
force=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-url)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --base-url requires a URL" >&2
        usage
        exit 1
      fi
      base_url=$2
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required but was not found on PATH" >&2
  exit 1
fi

files=(
  index.html
  doom.html
  javabox-direct.mjs
  javabox-direct.wasm
  javabox-direct.data
  xterm.js
  xterm.css
)

mkdir -p "$output_dir"
base_url=${base_url%/}
part_file=

cleanup() {
  if [ -n "$part_file" ]; then
    rm -f "$part_file"
  fi
}
trap cleanup EXIT HUP INT TERM

echo "Downloading roughly 76MB total (javabox-direct.data is about 72MB)."

for name in "${files[@]}"; do
  destination="$output_dir/$name"
  if [ "$force" -eq 0 ] && [ -s "$destination" ]; then
    echo "skip $name (already present)"
    continue
  fi

  echo "download $name"
  part_file="$destination.part"
  curl --fail --location --show-error \
    --output "$part_file" "$base_url/$name"
  mv "$part_file" "$destination"
  part_file=
done

for name in "${files[@]}"; do
  if [ ! -s "$output_dir/$name" ]; then
    echo "ERROR: missing or empty artifact: $output_dir/$name" >&2
    exit 1
  fi
done

trap - EXIT HUP INT TERM

echo "Prebuilt artifacts are ready in: $output_dir"
echo
echo "Next step:"
echo "  python3 build/serve.py $output_dir 3000"
echo "  http://localhost:3000/index.html   — Java editor"
echo "  http://localhost:3000/doom.html    — Doom"
