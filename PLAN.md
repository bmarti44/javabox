# JavaBox: Java Web Container via container2wasm

## Implementation Notes (Updated)

| Decision | Choice | Notes |
|----------|--------|-------|
| Container runtime | **Rancher Desktop (`~/.rd/bin/docker`)** | Use `~/.rd/bin/docker` — `nerdctl` unavailable (containerd socket not exposed) |
| Base image | **`oraclelinux:9-slim` (Docker Hub)** | No Oracle registry auth required; replaces `container-registry.oracle.com` |
| JDK flavor | **Eclipse Temurin JDK 21 via tarball** | `java-21-openjdk-devel` pulls 200+ GUI deps on OL9; tarball + jlink avoids this |
| c2w on macOS | **Colima x86_64 VM** | `build/convert.sh --mode arm-mac`; no macOS binary; Go GC crashes under QEMU user-mode |
| Networking in browser | **Null netdev (no server needed)** | Intercept `window.WebSocket` for `ws://127.0.0.1:8888/`; Linux eth0 fails gracefully; Java works without real networking |
| Dev server | **`python3 build/serve.py`** | `npx serve` breaks on corporate npm registry; Python server adds COOP/COEP headers |

---

## Project Overview

JavaBox is a browser-based Java development container that runs Oracle Linux + Oracle JDK inside a WASM-emulated environment using [container2wasm](https://github.com/container2wasm/container2wasm). It exposes a TypeScript API that lets JavaScript applications:

1. Write `.java` source files into the container's virtual filesystem
2. Compile them using `javac`
3. Run them using `java`
4. Capture stdout/stderr/exit codes
5. Make HTTP requests and TCP socket connections from inside Java code

The container persists across compile/run cycles — you boot it once and keep feeding it sources.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Browser                                                     │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  JavaBox TypeScript SDK (npm package)                  │  │
│  │                                                        │  │
│  │  - JavaContainer.boot(config)                          │  │
│  │  - container.fs.writeFile(path, content)               │  │
│  │  - container.fs.readFile(path)                         │  │
│  │  - container.compile(files, options)                   │  │
│  │  - container.run(mainClass, args)                      │  │
│  │  - container.exec(command)                             │  │
│  │  - container.onStdout / container.onStderr             │  │
│  └────────────────┬───────────────────────────────────────┘  │
│                   │                                          │
│  ┌────────────────▼───────────────────────────────────────┐  │
│  │  container2wasm Runtime (QEMU Wasm + Emscripten)       │  │
│  │                                                        │  │
│  │  ┌──────────────────────────────────────────────────┐  │  │
│  │  │  QEMU Wasm (x86_64 JIT via TCG)                 │  │  │
│  │  │  ┌────────────────────────────────────────────┐  │  │  │
│  │  │  │  Linux Kernel                              │  │  │  │
│  │  │  │  ┌──────────────────────────────────────┐  │  │  │  │
│  │  │  │  │  Oracle Linux 9 (slim)               │  │  │  │  │
│  │  │  │  │  Oracle JDK 21 (jlinked minimal)     │  │  │  │  │
│  │  │  │  │                                      │  │  │  │  │
│  │  │  │  │  /workspace  ← virtio-9p shared FS   │  │  │  │  │
│  │  │  │  └──────────────────────────────────────┘  │  │  │  │
│  │  │  └────────────────────────────────────────────┘  │  │  │
│  │  └──────────────────────────────────────────────────┘  │  │
│  │                                                        │  │
│  │  ┌─────────────────┐  ┌─────────────────────────────┐  │  │
│  │  │ c2w-net-proxy   │  │ Emscripten FS (virtio-9p)   │  │  │
│  │  │ (in-browser NW) │  │ JS ↔ guest shared mount     │  │  │
│  │  └─────────────────┘  └─────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘

           │ (WebSocket, for full TCP/UDP)
           ▼
┌─────────────────────────────┐
│  c2w-net Relay Server       │
│  (Go binary from c2w)       │
│  WebSocket ↔ TCP bridge     │
│  Deployed as Docker/systemd │
└─────────────────────────────┘
```

### Key Technology Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Emulator mode | `--to-js` (QEMU Wasm) | JIT via TCG is 3-5x faster than Bochs interpreter mode for x86_64 |
| Container arch | x86_64 | Oracle JDK x86_64 is the primary target; QEMU Wasm supports x86_64 JIT |
| Guest OS | Oracle Linux 9 Slim | Official Oracle base, minimal footprint, dnf for package management |
| JDK | Oracle JDK 21 LTS | Long-term support, `jlink` for minimal runtime image |
| FS sharing | virtio-9p via Emscripten FS | container2wasm's built-in mechanism for `--to-js` mode |
| Networking (HTTP/S) | c2w-net-proxy in-browser | No server needed; uses browser Fetch API; CORS-limited |
| Networking (TCP/UDP) | c2w-net relay via WebSocket | `?net=delegate=ws://host:port` mode; full packet forwarding |
| Package format | npm (TypeScript SDK) + CDN (WASM blob) | Standard web distribution |

### Networking Modes

container2wasm provides two networking modes. JavaBox should support both:

**Mode 1: Browser-only (HTTP/S only)**
- `c2w-net-proxy.wasm` runs as a WASM module in the browser
- Intercepts HTTP/S from guest → rewrites as browser `fetch()` calls
- Proxy env vars pre-configured inside guest: `http_proxy=http://192.168.127.253:80`
- HTTPS terminated at proxy, re-encrypted via fetch (proxy cert at `/.wasmenv/proxy.crt`)
- **Limitation:** CORS-restricted, no control over forbidden headers, HTTP/S only
- **Use when:** No relay server available, HTTP-only Java code

**Mode 2: Delegate (full TCP/UDP)**
- `c2w-net` binary runs on a server, listens on a WebSocket port
- All guest network packets forwarded over WebSocket to c2w-net
- c2w-net does real TCP/UDP on behalf of the guest
- **Limitation:** Requires server-side component
- **Use when:** Java code needs raw sockets, JDBC connections, non-HTTP protocols

---

## Repository Structure

```
javabox/
├── packages/
│   ├── sdk/                     # TypeScript SDK (npm package)
│   │   ├── src/
│   │   │   ├── index.ts         # Public API exports
│   │   │   ├── container.ts     # JavaContainer class
│   │   │   ├── filesystem.ts    # VirtualFS abstraction over virtio-9p
│   │   │   ├── process.ts       # Command execution over serial/pty
│   │   │   ├── compiler.ts      # javac wrapper with error parsing
│   │   │   ├── runner.ts        # java execution wrapper
│   │   │   ├── networking.ts    # Network config (browser vs delegate)
│   │   │   └── types.ts         # TypeScript interfaces
│   │   ├── package.json
│   │   └── tsconfig.json
│   │
│   └── relay/                   # Relay server packaging
│       ├── Dockerfile           # c2w-net in a container
│       ├── docker-compose.yml
│       └── README.md
│
├── container/
│   ├── Dockerfile               # Oracle Linux 9 + Oracle JDK 21 image
│   └── jlink-modules.txt        # Modules to include in minimal JDK
│
├── build/
│   ├── convert.sh               # c2w conversion script
│   ├── optimize.sh              # Brotli compression, chunking
│   └── cdn-upload.sh            # Upload WASM blob to CDN
│
├── web/
│   ├── index.html               # Demo page with xterm.js terminal
│   ├── playground.html          # Code editor + run button demo
│   └── server-headers.conf      # Required COOP/COEP headers
│
├── examples/
│   ├── hello-world/
│   ├── http-client/
│   ├── multi-file/
│   └── with-relay/
│
├── docs/
│   ├── GETTING_STARTED.md
│   ├── API.md
│   ├── NETWORKING.md
│   └── PERFORMANCE.md
│
└── scripts/
    ├── benchmark.sh             # Compile/run timing measurements
    └── ci.sh                    # GitHub Actions build pipeline
```

---

## Phase 0: Container Image Build & WASM Conversion

**Goal:** Build the Oracle Linux + Oracle JDK container, convert it to WASM, boot it in browser, prove `javac` and `java` work via xterm.js terminal.

### Step 0.1: Create the Container Image

Create `container/Dockerfile`:

```dockerfile
# Oracle Linux 9 slim base
FROM container-registry.oracle.com/os/oraclelinux:9-slim

# Install Oracle JDK 21
# Use Oracle Linux's built-in JDK packages
RUN microdnf install -y java-21-oracle-graalvm-jdk && \
    microdnf clean all

# Create a minimal JDK using jlink (reduces image size significantly)
RUN jlink \
    --module-path $JAVA_HOME/jmods \
    --add-modules java.base,java.compiler,java.instrument,java.logging,\
java.management,java.naming,java.net.http,java.rmi,java.scripting,\
java.security.jgss,java.security.sasl,java.sql,java.xml,\
jdk.compiler,jdk.crypto.ec,jdk.httpserver,jdk.jdwp.agent,\
jdk.management,jdk.net,jdk.unsupported,jdk.zipfs \
    --output /opt/jdk-minimal \
    --strip-debug \
    --no-man-pages \
    --no-header-files \
    --compress=zip-6

# Replace full JDK with minimal
RUN rm -rf $JAVA_HOME
ENV JAVA_HOME=/opt/jdk-minimal
ENV PATH="$JAVA_HOME/bin:$PATH"

# Create workspace directory (will be the virtio-9p mount point)
RUN mkdir -p /workspace

# Verify
RUN java -version && javac -version

# Set working directory
WORKDIR /workspace

# Default entrypoint is shell (container2wasm will use this)
CMD ["/bin/bash"]
```

**Build the image:**
```bash
docker build -t javabox:latest ./container/
```

**Verify locally first:**
```bash
docker run --rm -it javabox:latest bash -c '
  echo "public class Hello { public static void main(String[] a) { System.out.println(\"Hello from JavaBox\"); } }" > Hello.java &&
  javac Hello.java &&
  java Hello
'
```

### Step 0.2: Convert to WASM

Install container2wasm (latest release from https://github.com/container2wasm/container2wasm/releases):

```bash
# Download c2w binary (Linux amd64 example)
wget https://github.com/container2wasm/container2wasm/releases/latest/download/c2w-v0.8.1-linux-amd64.tar.gz
tar xzf c2w-v0.8.1-linux-amd64.tar.gz
sudo mv c2w c2w-net /usr/local/bin/

# Convert container to browser-runnable WASM+JS using QEMU Wasm (--to-js)
# This uses QEMU Wasm with JIT (TCG) for x86_64 — significantly faster than Bochs
c2w --to-js javabox:latest /tmp/javabox-out/htdocs/
```

The `--to-js` flag outputs:
- `out.js` — Emscripten-generated JS loader
- `out.wasm` — QEMU Wasm binary
- `out.data` — Packed filesystem (container rootfs + kernel)
- Additional support files

### Step 0.3: Set Up Browser Demo

**Required HTTP headers** (Cross-Origin Isolation for SharedArrayBuffer):

Create `web/server-headers.conf` (Apache example):
```apache
Header set Cross-Origin-Opener-Policy "same-origin"
Header set Cross-Origin-Embedder-Policy "require-corp"
```

For nginx:
```nginx
add_header Cross-Origin-Opener-Policy "same-origin";
add_header Cross-Origin-Embedder-Policy "require-corp";
```

**Create minimal demo page** `web/index.html`:

This page should:
1. Load xterm.js for terminal emulation
2. Load the container2wasm output JS
3. Include c2w-net-proxy.wasm for in-browser networking
4. Boot the container and connect terminal

Reference container2wasm's `examples/emscripten/` and `examples/emscripten-simple/` for the exact integration pattern. The simple example has no webpack dependency.

```bash
# Get the network proxy WASM
wget -O /tmp/javabox-out/htdocs/c2w-net-proxy.wasm \
  https://github.com/container2wasm/container2wasm/releases/latest/download/c2w-net-proxy.wasm

# Gzip it for browser loading
gzip -c /tmp/javabox-out/htdocs/c2w-net-proxy.wasm > /tmp/javabox-out/htdocs/c2w-net-proxy.wasm.gzip
```

### Step 0.4: Boot and Validate

Serve the files and test in browser:

```bash
# Using a simple server with correct headers
npx serve /tmp/javabox-out/htdocs/ --cors \
  --config '{"headers":[{"source":"**","headers":[{"key":"Cross-Origin-Opener-Policy","value":"same-origin"},{"key":"Cross-Origin-Embedder-Policy","value":"require-corp"}]}]}'
```

**Validation checklist:**
- [ ] Container boots in browser (expect 15-60 seconds depending on machine)
- [ ] Terminal shows Oracle Linux prompt
- [ ] `java -version` reports Oracle JDK 21
- [ ] `javac -version` works
- [ ] Can create, compile, and run a Hello World Java program via terminal
- [ ] Note boot time, memory usage, compile time for Hello World

**Record baseline metrics:**
```
Boot time:          _____ seconds
Memory (tab):       _____ MB
WASM blob size:     _____ MB (uncompressed)
WASM blob size:     _____ MB (Brotli compressed)
javac HelloWorld:   _____ seconds
java HelloWorld:    _____ seconds
```

### Step 0.5: Go/No-Go Decision

**Continue if:**
- Boot time < 120 seconds
- Compile time < 30 seconds for HelloWorld
- Total WASM payload < 1GB uncompressed
- No crash/hang during compilation

**Pivot if:**
- Boot time > 120 seconds → investigate wizer pre-boot snapshot
- Compile hangs → memory issue, investigate WASM memory limits
- Payload > 1GB → more aggressive jlink trimming needed

---

## Phase 1: TypeScript SDK — Filesystem & Command Execution

**Goal:** Build a TypeScript SDK that abstracts container2wasm's low-level interfaces (Emscripten FS, serial/PTY) into a clean API for writing files and executing commands.

### Step 1.1: Understand container2wasm's JS Interfaces

Before writing any SDK code, study these files from the container2wasm repo:
- `examples/emscripten/htdocs/src/index.ts` — How xterm-pty connects to the container
- `examples/emscripten-simple/htdocs/index.html` — Minimal example without webpack
- The Emscripten `Module.FS` API — how files are written to/read from the virtual FS
- The virtio-9p mount — how Emscripten FS paths map to guest paths

**Key insight:** In `--to-js` mode, the Emscripten `Module` object exposes:
- `Module.FS` — Emscripten's virtual filesystem API (MEMFS by default)
  - `FS.writeFile(path, data)` — write a file
  - `FS.readFile(path)` — read a file
  - `FS.mkdir(path)` — create directory
  - `FS.unlink(path)` — delete file
- These files are shared with the guest via virtio-9p mount
- The mount point mapping needs to be identified from container2wasm's QEMU Wasm config

**Key question to resolve:** What is the exact Emscripten FS path that maps to the guest's `/workspace`? This depends on QEMU Wasm's virtio-9p configuration. Check:
1. The QEMU command line generated by c2w (look for `-virtfs` or `-fsdev` flags)
2. The guest's `/etc/fstab` or mount configuration
3. Test empirically: write a file via `Module.FS.writeFile()` on the JS side, then `ls` the guest filesystem to find it

### Step 1.2: SDK Project Setup

```bash
mkdir -p packages/sdk/src
cd packages/sdk

# Initialize
npm init -y
npm install typescript @types/node --save-dev

# TypeScript config
cat > tsconfig.json << 'EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "lib": ["ES2020", "DOM"]
  },
  "include": ["src/**/*"]
}
EOF
```

### Step 1.3: Define the Public API

Create `packages/sdk/src/types.ts`:

```typescript
/** Configuration for booting the Java container */
export interface JavaContainerConfig {
  /** URL to the directory containing the c2w --to-js output files */
  wasmBaseUrl: string;

  /** Networking mode */
  networking?:
    | { mode: 'browser' }                              // HTTP/S only via Fetch API
    | { mode: 'delegate'; relayUrl: string }            // Full TCP/UDP via relay
    | { mode: 'none' };                                 // No networking

  /** Called when container writes to stdout */
  onStdout?: (data: string) => void;

  /** Called when container writes to stderr */
  onStderr?: (data: string) => void;

  /** Called when container is ready to accept commands */
  onReady?: () => void;

  /** Called on boot progress (optional, for loading UIs) */
  onProgress?: (stage: string, percent?: number) => void;

  /** Element to attach xterm.js terminal to (optional, for interactive mode) */
  terminalElement?: HTMLElement;
}

/** Result of a compile or run operation */
export interface ExecResult {
  /** Process exit code (0 = success) */
  exitCode: number;
  /** Captured stdout */
  stdout: string;
  /** Captured stderr */
  stderr: string;
  /** Execution time in milliseconds */
  durationMs: number;
}

/** Parsed Java compilation error */
export interface CompileError {
  file: string;
  line: number;
  column: number;
  message: string;
  kind: 'error' | 'warning' | 'note';
}

/** Compile result with parsed errors */
export interface CompileResult extends ExecResult {
  /** Parsed compilation errors/warnings */
  diagnostics: CompileError[];
}

/** File to write into the container */
export interface SourceFile {
  /** Path relative to /workspace (e.g., "com/example/Main.java") */
  path: string;
  /** File content */
  content: string;
}

/** Filesystem abstraction */
export interface VirtualFS {
  writeFile(path: string, content: string | Uint8Array): Promise<void>;
  readFile(path: string): Promise<string>;
  readFileBytes(path: string): Promise<Uint8Array>;
  exists(path: string): Promise<boolean>;
  mkdir(path: string, recursive?: boolean): Promise<void>;
  rm(path: string, recursive?: boolean): Promise<void>;
  ls(path: string): Promise<string[]>;
}
```

Create `packages/sdk/src/index.ts`:

```typescript
export { JavaContainer } from './container';
export type {
  JavaContainerConfig,
  ExecResult,
  CompileResult,
  CompileError,
  SourceFile,
  VirtualFS,
} from './types';
```

### Step 1.4: Implement the Container Class

Create `packages/sdk/src/container.ts`:

This is the core class. Implementation approach:

```typescript
import type {
  JavaContainerConfig,
  ExecResult,
  CompileResult,
  CompileError,
  SourceFile,
  VirtualFS,
} from './types';

export class JavaContainer {
  private config: JavaContainerConfig;
  private module: any; // Emscripten Module
  private ready: boolean = false;
  private _fs: VirtualFS;

  private constructor(config: JavaContainerConfig) {
    this.config = config;
    this._fs = null!; // initialized in boot
  }

  /** Boot the container. Returns when the JVM is ready to accept commands. */
  static async boot(config: JavaContainerConfig): Promise<JavaContainer> {
    const container = new JavaContainer(config);
    await container.initialize();
    return container;
  }

  get fs(): VirtualFS {
    return this._fs;
  }

  /**
   * Write source files and compile them.
   * Files are written relative to /workspace inside the container.
   */
  async compile(
    files: SourceFile[],
    options?: { classpath?: string[]; flags?: string[] }
  ): Promise<CompileResult> {
    // 1. Write all source files to the virtual FS
    for (const file of files) {
      await this._fs.writeFile(file.path, file.content);
    }

    // 2. Build javac command
    const sourceFiles = files
      .filter(f => f.path.endsWith('.java'))
      .map(f => `/workspace/${f.path}`);

    const cp = options?.classpath?.join(':') ?? '/workspace';
    const flags = options?.flags?.join(' ') ?? '';
    const cmd = `javac -cp ${cp} ${flags} ${sourceFiles.join(' ')} 2>&1; echo "EXIT:$?"`;

    // 3. Execute and parse
    const result = await this.exec(cmd);
    const diagnostics = this.parseJavacOutput(result.stderr + result.stdout);

    return { ...result, diagnostics };
  }

  /**
   * Run a compiled Java class.
   */
  async run(
    mainClass: string,
    args?: string[],
    options?: { classpath?: string[]; jvmFlags?: string[] }
  ): Promise<ExecResult> {
    const cp = options?.classpath?.join(':') ?? '/workspace';
    const jvmFlags = options?.jvmFlags?.join(' ') ?? '';
    const argsStr = args?.join(' ') ?? '';
    const cmd = `java -cp ${cp} ${jvmFlags} ${mainClass} ${argsStr} 2>&1; echo "EXIT:$?"`;

    return this.exec(cmd);
  }

  /**
   * Execute an arbitrary shell command inside the container.
   */
  async exec(command: string): Promise<ExecResult> {
    // Implementation depends on how container2wasm exposes command execution.
    //
    // Two approaches to investigate:
    //
    // APPROACH A: Serial/PTY
    // - Write command to the PTY input
    // - Capture output until a sentinel marker appears
    // - Parse exit code from the sentinel
    //
    // APPROACH B: Emscripten FS + script execution
    // - Write a shell script to the shared FS
    // - Write command that sources the script and captures output to a file
    // - Read the output file from Emscripten FS
    //
    // Approach B is more reliable for programmatic use because PTY output
    // parsing is fragile (terminal escape codes, interleaved output, etc.)

    throw new Error('TODO: implement based on container2wasm interface study');
  }

  // --- Private methods ---

  private async initialize(): Promise<void> {
    // 1. Load the Emscripten Module from wasmBaseUrl
    // 2. Configure networking mode
    // 3. Wait for Linux to boot (detect by watching serial output for login prompt or shell prompt)
    // 4. Initialize the VirtualFS wrapper
    // 5. Verify javac/java are accessible
    // 6. Fire onReady callback

    throw new Error('TODO: implement based on container2wasm interface study');
  }

  private parseJavacOutput(output: string): CompileError[] {
    // javac error format:
    // /workspace/Hello.java:3: error: ';' expected
    //     System.out.println("Hello")
    //                                ^
    // 1 error
    const diagnostics: CompileError[] = [];
    const regex = /^(.+\.java):(\d+): (error|warning|note): (.+)$/gm;
    let match: RegExpExecArray | null;
    while ((match = regex.exec(output)) !== null) {
      diagnostics.push({
        file: match[1].replace('/workspace/', ''),
        line: parseInt(match[2], 10),
        column: 0, // javac doesn't always report column in the same line
        message: match[4],
        kind: match[3] as 'error' | 'warning' | 'note',
      });
    }
    return diagnostics;
  }
}
```

### Step 1.5: Implement VirtualFS

Create `packages/sdk/src/filesystem.ts`:

```typescript
import type { VirtualFS } from './types';

/**
 * Wraps Emscripten's Module.FS API with the virtio-9p mount path mapping.
 *
 * IMPORTANT: The exact path mapping between Emscripten FS and guest FS
 * needs to be determined empirically in Phase 0. The QEMU Wasm virtio-9p
 * config determines which Emscripten FS directory maps to which guest path.
 *
 * Likely mapping (verify this):
 *   Emscripten FS: /share/workspace/  →  Guest: /workspace/
 *
 * Study these to determine the mapping:
 * - container2wasm's QEMU Wasm launch args (look for -virtfs)
 * - The Emscripten FS.mkdir calls in the generated out.js
 * - Empirical test: write a file via FS.writeFile, find it in guest
 */
export class EmscriptenVirtualFS implements VirtualFS {
  private fs: any; // Emscripten Module.FS
  private basePath: string; // Emscripten-side base path that maps to guest /workspace

  constructor(emscriptenFS: any, basePath: string) {
    this.fs = emscriptenFS;
    this.basePath = basePath;
  }

  private resolve(path: string): string {
    // Strip leading slash if present, prepend base path
    const clean = path.startsWith('/') ? path.slice(1) : path;
    return `${this.basePath}/${clean}`;
  }

  async writeFile(path: string, content: string | Uint8Array): Promise<void> {
    const fullPath = this.resolve(path);
    // Ensure parent directories exist
    const dir = fullPath.substring(0, fullPath.lastIndexOf('/'));
    this.mkdirRecursive(dir);
    this.fs.writeFile(fullPath, content);
  }

  async readFile(path: string): Promise<string> {
    const data = this.fs.readFile(this.resolve(path), { encoding: 'utf8' });
    return data;
  }

  async readFileBytes(path: string): Promise<Uint8Array> {
    return this.fs.readFile(this.resolve(path));
  }

  async exists(path: string): Promise<boolean> {
    try {
      this.fs.stat(this.resolve(path));
      return true;
    } catch {
      return false;
    }
  }

  async mkdir(path: string, recursive?: boolean): Promise<void> {
    if (recursive) {
      this.mkdirRecursive(this.resolve(path));
    } else {
      this.fs.mkdir(this.resolve(path));
    }
  }

  async rm(path: string, recursive?: boolean): Promise<void> {
    const fullPath = this.resolve(path);
    if (recursive) {
      // Emscripten doesn't have rm -rf, need to walk
      this.rmRecursive(fullPath);
    } else {
      this.fs.unlink(fullPath);
    }
  }

  async ls(path: string): Promise<string[]> {
    return this.fs.readdir(this.resolve(path))
      .filter((name: string) => name !== '.' && name !== '..');
  }

  private mkdirRecursive(path: string): void {
    const parts = path.split('/').filter(Boolean);
    let current = '';
    for (const part of parts) {
      current += '/' + part;
      try {
        this.fs.stat(current);
      } catch {
        this.fs.mkdir(current);
      }
    }
  }

  private rmRecursive(path: string): void {
    try {
      const stat = this.fs.stat(path);
      if (this.fs.isDir(stat.mode)) {
        const entries = this.fs.readdir(path)
          .filter((n: string) => n !== '.' && n !== '..');
        for (const entry of entries) {
          this.rmRecursive(path + '/' + entry);
        }
        this.fs.rmdir(path);
      } else {
        this.fs.unlink(path);
      }
    } catch {
      // File doesn't exist, ignore
    }
  }
}
```

### Step 1.6: Command Execution Strategy

**This is the hardest part of the SDK and requires experimentation.**

The challenge: container2wasm connects to the guest via a virtual serial port (PTY). There's no "run this command and get structured output" API. You're talking to a terminal.

**Recommended approach (script-based execution):**

```typescript
/**
 * Executes a command by:
 * 1. Writing a runner script to the shared FS
 * 2. Sending a command via PTY to execute the script
 * 3. Reading the output file from shared FS
 * 4. Parsing exit code from a marker file
 *
 * This avoids PTY output parsing which is fragile due to:
 * - Terminal escape sequences
 * - Line wrapping artifacts
 * - Interleaved prompt characters
 * - Timing issues
 */
async exec(command: string): Promise<ExecResult> {
  const id = crypto.randomUUID().replace(/-/g, '').slice(0, 8);
  const scriptPath = `/workspace/.javabox/run-${id}.sh`;
  const stdoutPath = `/workspace/.javabox/out-${id}.txt`;
  const stderrPath = `/workspace/.javabox/err-${id}.txt`;
  const exitCodePath = `/workspace/.javabox/exit-${id}.txt`;

  // Write the runner script via Emscripten FS
  const script = `#!/bin/bash
${command} > ${stdoutPath} 2> ${stderrPath}
echo $? > ${exitCodePath}
`;
  await this.fs.writeFile(`.javabox/run-${id}.sh`, script);

  const start = performance.now();

  // Send execution command via PTY
  // The exact mechanism depends on how container2wasm exposes PTY input
  this.sendToPty(`bash ${scriptPath}\n`);

  // Poll for the exit code file to appear (indicates completion)
  const exitCode = await this.pollForFile(`.javabox/exit-${id}.txt`, 120_000);

  const durationMs = performance.now() - start;
  const stdout = await this.fs.readFile(`.javabox/out-${id}.txt`);
  const stderr = await this.fs.readFile(`.javabox/err-${id}.txt`);

  // Cleanup
  await this.fs.rm(`.javabox/run-${id}.sh`);
  await this.fs.rm(`.javabox/out-${id}.txt`);
  await this.fs.rm(`.javabox/err-${id}.txt`);
  await this.fs.rm(`.javabox/exit-${id}.txt`);

  return {
    exitCode: parseInt(exitCode.trim(), 10),
    stdout,
    stderr,
    durationMs,
  };
}

private async pollForFile(path: string, timeoutMs: number): Promise<string> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await this.fs.exists(path)) {
      // Small delay to ensure file is fully written
      await new Promise(r => setTimeout(r, 100));
      return await this.fs.readFile(path);
    }
    await new Promise(r => setTimeout(r, 250));
  }
  throw new Error(`Command timed out after ${timeoutMs}ms`);
}
```

**Alternative approach (PTY parsing):**
If script-based execution doesn't work (e.g., virtio-9p mount isn't writable from Emscripten side, or there's a sync delay), fall back to PTY output parsing with sentinel markers:

```typescript
// Send command with sentinel markers
const sentinel = `__JAVABOX_${id}__`;
this.sendToPty(`${command}; echo "${sentinel}:$?"\n`);

// Parse PTY output buffer for the sentinel
// This is fragile and should only be used as a fallback
```

### Step 1.7: Integration Testing

Create `examples/hello-world/index.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <title>JavaBox - Hello World</title>
</head>
<body>
  <h1>JavaBox Hello World</h1>
  <pre id="output">Booting container...</pre>
  <script type="module">
    import { JavaContainer } from '/packages/sdk/dist/index.js';

    const output = document.getElementById('output');
    const log = (msg) => { output.textContent += '\n' + msg; };

    try {
      log('Creating container...');
      const container = await JavaContainer.boot({
        wasmBaseUrl: '/wasm/',
        networking: { mode: 'browser' },
        onProgress: (stage) => log(`Boot: ${stage}`),
        onReady: () => log('Container ready!'),
      });

      log('Writing source file...');
      await container.fs.writeFile('Hello.java', `
        public class Hello {
          public static void main(String[] args) {
            System.out.println("Hello from JavaBox!");
            System.out.println("Java version: " + System.getProperty("java.version"));
            System.out.println("OS: " + System.getProperty("os.name"));
          }
        }
      `);

      log('Compiling...');
      const compileResult = await container.compile([
        { path: 'Hello.java', content: '' } // already written above
      ]);
      log(`Compile: exit=${compileResult.exitCode}, ${compileResult.durationMs}ms`);
      if (compileResult.diagnostics.length > 0) {
        log('Errors: ' + JSON.stringify(compileResult.diagnostics, null, 2));
      }

      log('Running...');
      const runResult = await container.run('Hello');
      log(`Run: exit=${runResult.exitCode}, ${runResult.durationMs}ms`);
      log(`Output:\n${runResult.stdout}`);

    } catch (err) {
      log(`Error: ${err.message}`);
      console.error(err);
    }
  </script>
</body>
</html>
```

---

## Phase 2: Networking

**Goal:** Java code running inside the container can make HTTP requests and (with relay) TCP connections.

### Step 2.1: Browser-Only HTTP/S (c2w-net-proxy)

This should work out of the box from Phase 0 if c2w-net-proxy.wasm is loaded. The container's environment already has `http_proxy` and `https_proxy` set.

**Test inside container:**
```java
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

public class HttpTest {
    public static void main(String[] args) throws Exception {
        HttpClient client = HttpClient.newHttpClient();
        HttpRequest request = HttpRequest.newBuilder()
            .uri(URI.create("https://httpbin.org/get"))
            .build();
        HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());
        System.out.println("Status: " + response.statusCode());
        System.out.println("Body: " + response.body());
    }
}
```

**Known limitations to document:**
- CORS restrictions apply (can only reach CORS-enabled endpoints)
- Browser's forbidden headers (Host, Origin, etc.) cannot be controlled
- HTTPS is terminated at the in-browser proxy and re-encrypted via fetch
- Only HTTP/S — no raw TCP, UDP, WebSocket from Java code

**SDK configuration:**
```typescript
const container = await JavaContainer.boot({
  wasmBaseUrl: '/wasm/',
  networking: { mode: 'browser' }, // Loads c2w-net-proxy.wasm, appends ?net=browser
});
```

### Step 2.2: Relay Server for Full Networking (c2w-net)

**Relay setup** — `c2w-net` is a Go binary that ships with container2wasm. It's the relay.

Create `packages/relay/Dockerfile`:

```dockerfile
FROM golang:1.22-alpine AS builder

# Build c2w-net from source for reproducibility
RUN apk add --no-cache git
RUN git clone https://github.com/container2wasm/container2wasm.git /src
WORKDIR /src
RUN go build -o /c2w-net ./cmd/c2w-net

FROM alpine:3.19
COPY --from=builder /c2w-net /usr/local/bin/c2w-net
EXPOSE 8888
ENTRYPOINT ["c2w-net"]
CMD ["--listen", "0.0.0.0:8888"]
```

Create `packages/relay/docker-compose.yml`:

```yaml
version: '3.8'
services:
  relay:
    build: .
    ports:
      - "8888:8888"
    restart: unless-stopped
    # Optional: restrict outbound connections
    # networks:
    #   - relay-net
```

**Alternative: use pre-built binary directly:**
```bash
# Download from container2wasm releases
wget https://github.com/container2wasm/container2wasm/releases/latest/download/c2w-v0.8.1-linux-amd64.tar.gz
tar xzf c2w-v0.8.1-linux-amd64.tar.gz

# Run the relay
./c2w-net --listen 0.0.0.0:8888
```

**SDK configuration:**
```typescript
const container = await JavaContainer.boot({
  wasmBaseUrl: '/wasm/',
  networking: {
    mode: 'delegate',
    relayUrl: 'ws://localhost:8888',
  },
  // This maps to loading the page with ?net=delegate=ws://localhost:8888
});
```

**Test with sockets:**
```java
import java.io.*;
import java.net.*;

public class SocketTest {
    public static void main(String[] args) throws Exception {
        // This requires the relay — raw TCP doesn't work in browser-only mode
        Socket socket = new Socket("httpbin.org", 80);
        PrintWriter out = new PrintWriter(socket.getOutputStream(), true);
        BufferedReader in = new BufferedReader(new InputStreamReader(socket.getInputStream()));

        out.println("GET /get HTTP/1.1");
        out.println("Host: httpbin.org");
        out.println("Connection: close");
        out.println();

        String line;
        while ((line = in.readLine()) != null) {
            System.out.println(line);
        }
        socket.close();
    }
}
```

### Step 2.3: SDK Networking Abstraction

The SDK should handle the networking mode transparently. The URL query parameter (`?net=browser` or `?net=delegate=ws://...`) is how container2wasm selects the mode. The SDK needs to:

1. Generate the correct URL/config when loading the WASM
2. Ensure c2w-net-proxy.wasm is available for browser mode
3. Validate relay connectivity for delegate mode (WebSocket handshake check)

Add to `packages/sdk/src/networking.ts`:

```typescript
export interface NetworkConfig {
  mode: 'browser' | 'delegate' | 'none';
  relayUrl?: string;
}

export function validateNetworkConfig(config: NetworkConfig): void {
  if (config.mode === 'delegate' && !config.relayUrl) {
    throw new Error('Delegate networking requires relayUrl');
  }
  if (config.relayUrl && !config.relayUrl.startsWith('ws://') && !config.relayUrl.startsWith('wss://')) {
    throw new Error('relayUrl must be a WebSocket URL (ws:// or wss://)');
  }
}

export async function checkRelayConnectivity(relayUrl: string): Promise<boolean> {
  return new Promise((resolve) => {
    const ws = new WebSocket(relayUrl);
    const timeout = setTimeout(() => { ws.close(); resolve(false); }, 5000);
    ws.onopen = () => { clearTimeout(timeout); ws.close(); resolve(true); };
    ws.onerror = () => { clearTimeout(timeout); resolve(false); };
  });
}
```

---

## Phase 3: Optimization

**Goal:** Reduce boot time, payload size, and improve runtime performance.

### Step 3.1: JDK Trimming

The jlink command in Phase 0 already creates a minimal JDK. Further optimize:

```bash
# Inside the container, analyze which modules are actually used
java --list-modules  # See what's included

# Profile a typical workload to find required modules
jdeps --print-module-deps /workspace/YourApp.class
```

**Conservative minimal set for compilation + basic execution:**
```
java.base         # Core (always required)
jdk.compiler      # javac
java.compiler     # Compiler API
java.logging      # java.util.logging
java.net.http     # HTTP client (Java 11+)
jdk.crypto.ec     # TLS support
jdk.zipfs         # JAR handling
```

**Extended set for networking/IO-heavy code:**
```
java.sql          # JDBC
java.naming       # JNDI
java.xml          # XML parsing
java.management   # JMX
java.rmi          # RMI
java.security.jgss
java.security.sasl
jdk.net           # Unix sockets
jdk.httpserver    # Embedded HTTP server
```

### Step 3.2: WASM Payload Optimization

```bash
# Measure current sizes
du -sh /tmp/javabox-out/htdocs/

# Brotli compress the WASM file (best compression for web delivery)
brotli -q 11 -o out.wasm.br out.wasm

# Also compress the data file
brotli -q 11 -o out.data.br out.data

# Chunk large files for parallel download
# Split into 10MB chunks for CDN delivery
split -b 10M out.wasm out.wasm.chunk.
```

### Step 3.3: Boot Time Optimization

**wizer pre-boot (if supported by QEMU Wasm mode):**
wizer can snapshot the WASM module after initialization, so subsequent boots skip kernel boot. This is noted as "WASI only as of now" in container2wasm docs — check if it works with `--to-js` mode.

**Practical boot optimizations:**
1. Disable unnecessary kernel modules in the container
2. Minimize `/etc/init.d` services
3. Set `init=/bin/bash` or a minimal init if possible
4. Pre-warm javac on first boot (JVM class loading is slow the first time)

### Step 3.4: Memory Tuning

Emscripten WASM memory defaults to 256MB initial / 2GB max. Java needs more:

```javascript
// In the Emscripten Module config
var Module = {
  // Initial memory (must be enough for JVM + kernel)
  INITIAL_MEMORY: 512 * 1024 * 1024,  // 512MB
  // Allow growth up to 4GB (requires recent browsers)
  MAXIMUM_MEMORY: 4096 * 1024 * 1024,  // 4GB
  ALLOW_MEMORY_GROWTH: true,
};
```

Inside the Java container, limit JVM heap:
```bash
# In container setup script
export JAVA_TOOL_OPTIONS="-Xms64m -Xmx256m -XX:+UseSerialGC -XX:MaxRAMPercentage=50"
```

---

## Phase 4: Relay Server (Production)

**Goal:** Deploy c2w-net as a production-ready relay for full TCP/UDP networking.

### Step 4.1: Production Relay

If `c2w-net` meets your needs, use it directly. If you need more control (rate limiting, auth, logging), wrap it or build a custom relay.

**Security considerations for the relay:**
- The relay forwards arbitrary TCP/UDP from browser clients to the internet
- **Rate limiting is mandatory** — without it, the relay is an open proxy
- Restrict allowed destination ports (e.g., 80, 443, 5432, 3306)
- Require authentication (API key in WebSocket handshake)
- Log connections for abuse monitoring

Create `packages/relay/relay-config.yaml`:

```yaml
listen:
  address: "0.0.0.0"
  port: 8888
  tls:
    cert: /etc/relay/cert.pem
    key: /etc/relay/key.pem

security:
  # Require API key in WebSocket URL: ws://relay.example.com:8888?key=xxx
  api_keys:
    - "your-api-key-here"

  # Allowed destination ports
  allowed_ports:
    - 80      # HTTP
    - 443     # HTTPS
    - 5432    # PostgreSQL
    - 3306    # MySQL
    - 8080    # Common dev port
    - 8443    # Common dev TLS port

  # Rate limiting per client IP
  rate_limit:
    connections_per_minute: 30
    bytes_per_minute: 10_000_000  # 10MB

  # Block private/internal networks
  block_private_ips: true

logging:
  level: info
  format: json
```

**Note:** If c2w-net doesn't support these features natively, you'll need a reverse proxy (nginx/caddy) in front of it, or fork c2w-net to add them. The Go source is at `cmd/c2w-net/` in the container2wasm repo.

### Step 4.2: Deployment

```bash
# Docker
docker build -t javabox-relay ./packages/relay/
docker run -d -p 8888:8888 --name javabox-relay javabox-relay

# Or systemd
sudo cp c2w-net /usr/local/bin/
sudo cat > /etc/systemd/system/javabox-relay.service << 'EOF'
[Unit]
Description=JavaBox Network Relay
After=network.target

[Service]
ExecStart=/usr/local/bin/c2w-net --listen 0.0.0.0:8888
Restart=always
User=nobody
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now javabox-relay
```

---

## Phase 5: Developer Experience & Distribution

### Step 5.1: NPM Package

```json
{
  "name": "@javabox/sdk",
  "version": "0.1.0",
  "description": "Run Java in the browser via Oracle Linux + Oracle JDK in WASM",
  "main": "dist/index.js",
  "module": "dist/index.mjs",
  "types": "dist/index.d.ts",
  "files": ["dist/"],
  "scripts": {
    "build": "tsc && tsc -p tsconfig.esm.json",
    "test": "vitest"
  },
  "peerDependencies": {},
  "license": "Apache-2.0"
}
```

### Step 5.2: CDN Distribution for WASM Blobs

The WASM files are too large for npm. Host them on a CDN:

```typescript
const container = await JavaContainer.boot({
  wasmBaseUrl: 'https://cdn.javabox.dev/v0.1.0/', // Versioned CDN URL
  networking: { mode: 'browser' },
});
```

CDN structure:
```
https://cdn.javabox.dev/
  v0.1.0/
    out.js
    out.wasm          (or out.wasm.br for Brotli)
    out.data           (or out.data.br)
    c2w-net-proxy.wasm
    manifest.json      (sizes, checksums, version info)
```

### Step 5.3: Error Handling & DX

**Compile error formatting:**
```typescript
// Return structured errors that IDEs/editors can consume
interface CompileError {
  file: string;       // "com/example/Main.java"
  line: number;       // 15
  column: number;     // 22
  message: string;    // "';' expected"
  kind: 'error' | 'warning' | 'note';
}
```

**Boot failure diagnostics:**
```typescript
// Detect common issues and provide actionable messages
class JavaBoxError extends Error {
  constructor(
    message: string,
    public code: 'COOP_MISSING' | 'COEP_MISSING' | 'SAB_UNAVAILABLE' |
                 'WASM_LOAD_FAILED' | 'BOOT_TIMEOUT' | 'RELAY_UNREACHABLE',
    public suggestion: string
  ) {
    super(message);
  }
}

// Example: Missing Cross-Origin headers
throw new JavaBoxError(
  'SharedArrayBuffer is not available',
  'SAB_UNAVAILABLE',
  'Add Cross-Origin-Opener-Policy: same-origin and Cross-Origin-Embedder-Policy: require-corp headers to your server'
);
```

---

## Open Questions (Resolve During Implementation)

1. **Emscripten FS → guest path mapping:** What Emscripten FS path maps to `/workspace` inside the guest? Must be determined empirically in Phase 0.

2. **PTY vs shared-FS command execution:** Can the SDK write scripts to the shared FS and have the guest execute them? Or must all commands go through the PTY? Depends on whether the virtio-9p mount is writable from the JS/Emscripten side.

3. **Boot detection:** How do you programmatically detect when the guest has finished booting and is ready for commands? Options: poll for a sentinel file, parse serial output for shell prompt, or set up a boot completion hook in the container's init scripts.

4. **Oracle JDK availability:** Verify that `container-registry.oracle.com/os/oraclelinux:9-slim` + `java-21-oracle-graalvm-jdk` is the correct package. May need `oracle-java-21-jdk` depending on the repo configuration. Check `microdnf search java` inside the container.

5. **container2wasm version:** Pin to a specific release. The `--to-js` flag with QEMU Wasm was introduced in v0.8.0. Latest as of this writing is v0.8.1.

6. **GraalVM vs standard Oracle JDK:** The Dockerfile above uses `java-21-oracle-graalvm-jdk` which is GraalVM. If you want standard Oracle JDK, use the Oracle JDK RPM from oracle.com or the `java-21-oracle-javase-jdk` package if available.

---

## Success Criteria

| Metric | Target | Stretch |
|--------|--------|---------|
| Boot time | < 60s | < 30s |
| HelloWorld compile | < 15s | < 5s |
| HelloWorld run | < 5s | < 2s |
| WASM payload (compressed) | < 300MB | < 150MB |
| Browser memory usage | < 2GB | < 1GB |
| HTTP request from Java | Works | Works without relay |
| TCP socket from Java | Works (with relay) | — |
| API: write → compile → run | < 30s total | < 15s total |
