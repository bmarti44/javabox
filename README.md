# JavaBox

Run Java in the browser. No server-side JVM required.

JavaBox packages an Oracle Linux 9 + JDK 21 container into browser-runnable WebAssembly using [container2wasm](https://github.com/container2wasm/container2wasm). A TypeScript SDK exposes a `compile()` / `run()` API that lets your JavaScript application write, compile, and execute Java code entirely inside the user's browser tab.

## How It Works

```
Your JS app
  └── @javabox/sdk
        └── container2wasm runtime (Emscripten + QEMU Wasm)
              └── Linux kernel (emulated x86_64)
                    └── Oracle Linux 9-slim
                          └── JDK 21 (jlinked minimal)
```

Files are shared between JavaScript and the emulated container via a virtio-9p mount. The SDK writes `.java` files into that mount, runs `javac` and `java` inside the container, and streams stdout/stderr back to your callbacks.

## Repository Structure

```
container/          Dockerfile — Oracle Linux 9 + Temurin JDK 21
build/              Build scripts (convert, optimize, serve)
web/                Demo pages (terminal + Monaco editor playground)
packages/
  sdk/              TypeScript SDK (@javabox/sdk)
  relay/            c2w-net relay server (optional — for full TCP/UDP networking)
examples/           Minimal usage examples
scripts/            CI and benchmark helpers
PLAN.md             Full project specification
```

## Prerequisites

| Tool | Platform | Purpose | Install |
|------|----------|---------|---------|
| [Rancher Desktop](https://rancherdesktop.io) | macOS | Container build | `brew install --cask rancher` |
| [Colima](https://github.com/abiosoft/colima) | macOS arm64 | WASM conversion (x86_64 VM) | `brew install colima` |
| container2wasm v0.8.3 | Linux x86_64 | WASM conversion (fast/CI) | See Step 2 |
| Node.js 20+ | All | SDK build, local dev server | `brew install node` |
| brotli | All | Optional compression | `brew install brotli` |

## Step 1 — Build the Container Image

> **macOS**: Rancher Desktop must be running. The build uses `~/.rd/bin/docker`.

```sh
~/.rd/bin/docker build \
  --platform linux/amd64 \
  -t javabox:latest \
  ./container/
```

Smoke test (verify javac and java work):

```sh
~/.rd/bin/docker run --rm --platform linux/amd64 javabox:latest bash -c '
  java -version
  javac -version
  echo "public class Test { public static void main(String[] a) { System.out.println(\"OK\"); } }" > /tmp/Test.java
  javac /tmp/Test.java -d /tmp
  java -cp /tmp Test
'
```

## Step 2 — Convert to WASM

The conversion step is the only platform-sensitive operation. It produces static artifacts
(`out.wasm`, `out.js`, `out.data`) that are reused for all subsequent development — you only
re-run this when the `container/Dockerfile` changes.

`build/convert.sh` auto-detects your platform, or you can pass `--mode` explicitly.

### On Apple Silicon macOS (`--mode arm-mac`)

Uses a [Colima](https://github.com/abiosoft/colima) x86_64 VM for full system emulation.
Slow on first run (~20–40 min); the VM is reused on subsequent runs so re-conversion is faster.

> **Why:** container2wasm internally compiles `runc` with Go 1.24. Go 1.24's GC crashes under
> QEMU user-mode emulation on ARM. Colima runs a full x86_64 VM (not user-mode emulation),
> so Go executes natively inside it.

```sh
# Install colima + its x86_64 guest agent + qemu (one-time setup)
brew install colima lima-additional-guestagents qemu

# Convert (auto-detects arm-mac mode; starts x86_64 VM on first run)
./build/convert.sh ~/javabox-wasm

# Or explicitly:
./build/convert.sh --mode arm-mac ~/javabox-wasm
```

The Colima VM (profile `javabox-x86`) stays running after the first conversion and is
reused automatically. Stop it when not needed:

```sh
colima stop --profile javabox-x86
```

### On Linux x86_64 (`--mode linux`)

Uses the native c2w binary directly. Fast (~5–10 min). Use this in CI pipelines and
on Linux build machines.

```sh
# Install c2w v0.8.3 once
wget -qO- https://github.com/container2wasm/container2wasm/releases/download/v0.8.3/container2wasm-v0.8.3-linux-amd64.tar.gz \
  | tar xz && sudo mv c2w c2w-net /usr/local/bin/

# Convert (auto-detects linux mode)
./build/convert.sh /tmp/javabox-wasm

# Or explicitly:
./build/convert.sh --mode linux /tmp/javabox-wasm
```

### Output files

Both modes produce the same artifacts:

| File | Description |
|------|-------------|
| `out.js` | Emscripten JS loader |
| `out.wasm` | QEMU Wasm binary |
| `out.data` | Packed container filesystem |
| `c2w-net-proxy.wasm` | In-browser HTTP proxy (browser networking mode) |

## Step 3 — Serve the Demo (Optional Compression)

The WASM files require two HTTP headers to enable `SharedArrayBuffer` (used by the QEMU JIT):

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

**Quick local serve** (sets headers automatically via `build/serve-config.json`):

```sh
npx serve /tmp/javabox-out/htdocs --config build/serve-config.json
# open http://localhost:3000
```

**Optional — Brotli compression** before serving/deploying:

```sh
# Requires: brew install brotli
./build/optimize.sh /tmp/javabox-out/htdocs
```

This produces `.br` pre-compressed files and a `manifest.json` with SHA-256 checksums.

## Step 4 — Use the SDK

```sh
cd packages/sdk
npm install
npm run build        # compiles TypeScript
npx tsc --noEmit     # type-check only
```

Basic usage in your web app:

```typescript
import { JavaContainer } from '@javabox/sdk';

const container = await JavaContainer.boot({
  wasmBaseUrl: '/htdocs/',
  onStdout: (s) => console.log(s),
  onStderr: (s) => console.error(s),
});

const result = await container.compile([{
  path: 'Hello.java',
  content: `
    public class Hello {
      public static void main(String[] args) {
        System.out.println("Hello from WASM!");
      }
    }
  `,
}]);

if (result.exitCode === 0) {
  await container.run('Hello');
}
```

See `examples/hello-world/index.html` for a complete working example.

## Networking

Three modes are available:

| Mode | Description | Requires |
|------|-------------|---------|
| `none` (default) | No outbound network | Nothing |
| `browser` | HTTP/S via browser Fetch API | `c2w-net-proxy.wasm` (bundled) |
| `delegate` | Full TCP/UDP via WebSocket relay | `packages/relay/` deployed |

## Project Status

| Phase | Description | Status |
|-------|-------------|--------|
| 0 | Container image (OL9 + JDK 21) | Done |
| 0 | WASM conversion (c2w --to-js) | arm-mac: Colima x86 VM / linux: native c2w |
| 1 | TypeScript SDK (compile/run/fs) | Scaffolded, pending live WASM |
| 2 | Networking (browser + relay) | Scaffolded |
| 3 | Optimization (jlink, Brotli) | Scripts ready |
| 4 | Relay server | Dockerfile ready |
| 5 | DX (examples, benchmarks) | Scaffolded |

## Known Constraints

- **Heap**: Container defaults to `-Xms64m -Xmx256m` via `JAVA_TOOL_OPTIONS` in the Dockerfile
- **Boot time**: First load is slow (~30–120s depending on connection) due to WASM bundle size
- **Browser support**: Requires SharedArrayBuffer → Chrome 92+, Firefox 79+, Safari 15.2+, Edge 92+
- **HTTPS required in production**: SharedArrayBuffer is only available in secure contexts

## Development

```sh
# Type-check the SDK
cd packages/sdk && npx tsc --noEmit

# Run CI checks (type-check + container build + smoke test)
./scripts/ci.sh

# Benchmark (requires a running WASM instance)
./scripts/benchmark.sh
```
