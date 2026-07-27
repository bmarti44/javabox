# JavaBox — Agent Guidance

This file describes the codebase structure, key constraints, and conventions for AI agents working in this repository.

## What This Project Is

JavaBox runs JDK 21 in the browser via WebAssembly. It supports two execution modes:

1. **Direct WASM** (fast): OpenJDK Zero interpreter compiled directly to WASM via Emscripten. Architecture: Browser → Emscripten WASM (OpenJDK Zero C++ interpreter) → JVM → CompileServer. Target: ~3-5s boot.

2. **QEMU mode** (legacy): Container2wasm pipeline. Architecture: Browser → Emscripten WASM (QEMU) → TCG JIT → Linux kernel → JVM. Current: ~55s boot.

Both modes expose the same CompileServer protocol (JBOX_PING/JBOX_COMPILE/JBOX_DOOM) and the same TypeScript SDK API.

## Repository Layout

```
openjdk/            OpenJDK 21u git submodule (branch: wasm-emscripten — carries the Emscripten port)
third-party/
  libffi-emscripten/ libffi git submodule (branch: wasm-emscripten)
container/          Alpine Linux 3.21 + JDK 21 (Dockerfile) — QEMU mode
build/
  build-direct.sh   Orchestrate full direct WASM build
  build-jvm-wasm.sh Compile OpenJDK Zero → libjvm.a via Emscripten
  build-jdk-native.sh  Build JDK native static libraries
  build-jdk-modules.sh  jlink JDK class library on host
  build-doom-jar.sh     Compile Doom Java sources on host
  link-direct-wasm.sh   Final emcc link → javabox-direct.js + .wasm + .data
  jdk-detect.sh      JDK discovery and version validation
  fetch-prebuilt.sh  Download deployed WASM artifacts
  jvm-stdin-bridge.c    SharedArrayBuffer stdin ring buffer for direct mode
  convert.sh        c2w conversion — QEMU mode
  serve-config.json, serve.py  Local serving with COOP/COEP headers
web/
  index.html        Main UI — dual mode (?mode=direct or ?mode=qemu)
  doom.html         Doom frontend — dual mode
packages/
  sdk/              TypeScript SDK (@javabox/sdk) — compile/run/fs API
examples/           Usage examples
tests/              Playwright e2e tests (support both modes via JAVABOX_MODE env)
PLAN.md             Full project specification and phase breakdown
```

## Direct WASM build environment

Use `JAVABOX_BOOT_JDK` for the boot JDK (20 or 21) and `JAVABOX_JDK21_HOME` for the exact JDK 21 used by jlink. `build/jdk-detect.sh` validates these versions and fails with an actionable message if detection cannot find a match.

Doom needs an IWAD that is not redistributed here: put Freedoom's `freedoom1.wad` in `container/doom/` before building with `--with-doom` (see README). Everything else builds without it.

## The OpenJDK Emscripten port

The port lives on the `wasm-emscripten` branch of the `openjdk` submodule. Its shape, so changes land in the right place:

- **Two translation units carry real logic:** `src/hotspot/os/emscripten/os_emscripten.cpp` and `src/hotspot/os_cpu/emscripten_zero/os_emscripten_zero.cpp`. HotSpot compiles those directories wholesale, so both need their full companion file sets (modelled on `os/bsd` and `os_cpu/bsd_zero`), but the rest are thin headers and stubs.
- **`src/hotspot/os/posix/*` is reused unchanged.** Autoconf sets `VAR_OS_TYPE=unix` for `emscripten`, so threading, semaphores and perf memory come from the stock POSIX layer. Do not fork those files.
- **`src/hotspot/cpu/zero/*` is stock.** There is no CPU-port work; Zero already targets a stack machine.
- **There is no `src/java.base/emscripten/`.** java.base natives build from `share/` + `unix/` only; that work is make-system wiring, not new C.
- **libnet is deliberately not linked.** `_NET_*`, `_initInetAddressIDs` and friends become auto-generated JS stubs via `-sERROR_ON_UNDEFINED_SYMBOLS=0`. Networking being stubbed is by design, not a bug to chase.

Two mechanisms replace things WASM does not have:

- **No dynamic loader.** `os::dll_lookup` in `os_emscripten.cpp` resolves JNI entry points through a static name → address table that `build/link-direct-wasm.sh` generates into `build/static-symbols.c`. That table is also the only thing referencing those natives, so without it wasm-ld garbage-collects every one of them. It scans the four java.base archives *and* `build/jvm-main.o`, which holds the headless AWT `initIDs()` stubs. `build/build-jdk-modules.sh` touches empty placeholder `.so` files so `System.loadLibrary` still succeeds.
- **No process stdin.** In the browser, fd 0 is a SharedArrayBuffer ring buffer in `build/jvm-main.c`; `handleRead`/`handleAvailable` in `src/java.base/unix/native/libjava/io_util_md.c` have `__EMSCRIPTEN__` branches that drain it. Under Node.js the flag stays off and the normal `read()` path is used.

Known, understood divergences from the shipped reference module: the rebuilt binary imports `os_getChildren`, `os_getCmdlineAndUserInfo`, `os_getParentPidAndTimings`, `os_initNative` (ProcessHandleImpl has no emscripten variant) and `sigsuspend` (from `signals_posix.cpp`'s SR_handler). None are reachable in WASM.

## Container Build

- Base image: `oraclelinux:9-slim` from Docker Hub (no auth required)
- JDK: Eclipse Temurin JDK 21 installed via tarball, then shrunk with `jlink`
- Must always build with `--platform linux/amd64`
- Container runtime: **Rancher Desktop** (`~/.rd/bin/docker`) — NOT Docker Desktop, NOT plain `docker`
  - `nerdctl` does not work here because Rancher Desktop is running the `dockerd` (moby) engine, not containerd
  - Use `~/.rd/bin/docker` or add `~/.rd/bin` to `$PATH`

Build command:
```sh
~/.rd/bin/docker build --platform linux/amd64 -t javabox:latest ./container/
```

Smoke test:
```sh
~/.rd/bin/docker run --rm --platform linux/amd64 javabox:latest bash -c 'java -version && javac -version'
```

## WASM Conversion (c2w) — Two Modes

`build/convert.sh` auto-detects the platform, or accepts `--mode arm-mac|linux`.

The output (`out.wasm`, `out.js`, `out.data`) is a **static artifact** — only re-run conversion when `container/Dockerfile` changes.

### `--mode arm-mac` (Apple Silicon macOS)

Uses a Colima x86_64 VM (`brew install colima`). Slow on first run (~20–40 min); VM is reused on subsequent runs.

```sh
./build/convert.sh --mode arm-mac ~/javabox-wasm
```

**Why Colima, not QEMU user-mode:**
- c2w's BuildKit compiles `runc` using Go 1.24 for amd64
- Go 1.24's GC (`gcBgMarkWorker`) crashes under QEMU **user-mode** emulation on ARM
- `tonistiigi/binfmt --install all` does NOT fix this
- Colima with `--arch x86_64` runs a full x86_64 VM (QEMU full system emulation) — Go runs natively inside it, no crash

Colima VM profile name: `javabox-x86` (created automatically by the script).

### `--mode linux` (Linux x86_64 — fast, for CI pipelines)

Uses the native c2w binary. Fast (~5–10 min). Use in CI pipelines and on Linux build machines.

```sh
# Install c2w once
wget -qO- https://github.com/container2wasm/container2wasm/releases/download/v0.8.3/container2wasm-v0.8.3-linux-amd64.tar.gz \
  | tar xz && sudo mv c2w c2w-net /usr/local/bin/

./build/convert.sh --mode linux /tmp/javabox-wasm
```

## TypeScript SDK (`packages/sdk/`)

- Entry: `packages/sdk/src/index.ts`
- Types: `packages/sdk/src/types.ts` — all public interfaces
- Key class: `packages/sdk/src/container.ts` — `JavaContainer.boot()`, `compile()`, `run()`, `exec()`
- Build: `cd packages/sdk && npm run build` (uses tsc)
- Type-check only: `cd packages/sdk && npx tsc --noEmit`

**Open questions that must be resolved empirically against a live WASM build:**
- `EMSCRIPTEN_WORKSPACE_PATH` in `container.ts` — the exact path for the virtio-9p shared mount
- Boot sentinel detection — confirm `/etc/profile.d/javabox-ready.sh` runs on QEMU Wasm startup
- PTY strategy — `process.ts` has two stub strategies (A: script+sentinel, B: xterm-pty)

## Serving the WASM Output

The WASM output requires these HTTP headers (SharedArrayBuffer dependency):
```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

For local dev: `npx serve <output-dir> --config build/serve-config.json`

## Key Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Base OS | `oraclelinux:9-slim` | Matches project spec; small; no auth needed |
| JDK | Eclipse Temurin 21 via tarball | `java-21-openjdk-devel` pulls 200+ GUI deps on OL9 |
| jlink compression | `--compress=zip-6` | `--compress=2` deprecated in JDK 21; `--strip-debug` requires objcopy |
| c2w mode | `--to-js` (QEMU Wasm/TCG) | Full x86_64 Linux emulation in browser |
| Networking default | `c2w-net-proxy.wasm` | HTTP/S only via browser Fetch, no relay needed |
| Container runtime | Rancher Desktop `dockerd` | User preference; nerdctl not available (containerd not running) |

## What Not To Do

- Do not run `docker build` without `--platform linux/amd64` — results in aarch64 packages on Apple Silicon
- Do not use `--strip-debug` in jlink — requires `objcopy` (binutils) which is not installed
- Do not attempt c2w conversion on macOS/Apple Silicon — it will fail at the runc build step
- Do not change the `CMD` in the Dockerfile away from `["/bin/bash", "--login"]` — the `--login` flag is required for `/etc/profile.d/javabox-ready.sh` to execute at container start
