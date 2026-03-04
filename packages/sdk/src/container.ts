/**
 * container.ts — JavaContainer: the main SDK entry point.
 *
 * Manages the lifecycle of a container2wasm QEMU Wasm session:
 *   1. Load and initialize the Emscripten module (WASM + data)
 *   2. Wait for the Linux guest to boot
 *   3. Expose VirtualFS for file operations
 *   4. Execute compile/run/exec commands via the script-file mechanism
 *
 * IMPORTANT: Several implementation details depend on empirical testing
 * against the actual c2w --to-js output. These are marked with TODO comments.
 * Complete them during Phase 1 after Phase 0 (container boot validation).
 */

import type {
  JavaContainerConfig,
  ExecResult,
  CompileResult,
  SourceFile,
  VirtualFS,
  CompileOptions,
  RunOptions,
} from './types';
import { JavaBoxError } from './types';
import { EmscriptenVirtualFS, type EmscriptenModule } from './filesystem';
import { ScriptExecutor, type PtyInterface } from './process';
import { buildJavacCommand, toCompileResult } from './compiler';
import { buildJavaCommand } from './runner';
import {
  validateNetworkConfig,
  buildNetQueryParam,
  checkRelayConnectivity,
} from './networking';

/**
 * The Emscripten FS path that corresponds to the guest's /workspace.
 * This MUST be verified empirically in Phase 0 before this SDK can work.
 *
 * How to find it:
 *   1. Run `./build/convert.sh` to get the c2w output
 *   2. Open the browser's console on index.html
 *   3. Run: Module.FS.readdir('/')  — look for a 'share' or similar directory
 *   4. Drill down to find the path that contains 'workspace'
 *   5. Write a test file and confirm it's visible inside the guest container
 *
 * Common patterns observed in container2wasm QEMU Wasm output:
 *   '/share/workspace'  — when c2w mounts the 9p share at /share
 *   '/workspace'        — when the Emscripten FS root IS the workspace
 *
 * Update this constant after Phase 0 validation.
 */
const EMSCRIPTEN_WORKSPACE_PATH = '/share/workspace'; // TODO: verify in Phase 0

/**
 * Emscripten FS path for direct WASM mode.
 * In direct mode, there is no QEMU/virtio-9p layer. The JVM runs directly
 * in WASM with a MEMFS filesystem. Files are written to /workspace directly
 * on the MEMFS root.
 */
const DIRECT_WORKSPACE_PATH = '/workspace';

export class JavaContainer {
  private readonly config: JavaContainerConfig;
  private module!: EmscriptenModule;
  private _fs!: VirtualFS;
  private executor!: ScriptExecutor;
  private pty!: PtyInterface;
  private _ready = false;

  private constructor(config: JavaContainerConfig) {
    this.config = config;
  }

  /**
   * Boot the Java container. Returns when the JVM is ready to accept commands.
   *
   * This is the primary entry point for the SDK:
   *   const container = await JavaContainer.boot({ wasmBaseUrl: '...' });
   */
  static async boot(config: JavaContainerConfig): Promise<JavaContainer> {
    const container = new JavaContainer(config);
    await container.initialize();
    return container;
  }

  /** The virtual filesystem for reading/writing files inside the container. */
  get fs(): VirtualFS {
    return this._fs;
  }

  /**
   * Write source files to the container and compile them with javac.
   *
   * Files are written to /workspace/<path> inside the container.
   * The compilation classpath defaults to /workspace.
   */
  async compile(files: SourceFile[], options?: CompileOptions): Promise<CompileResult> {
    this.assertReady();

    // Write source files to the container FS
    for (const file of files) {
      await this._fs.writeFile(file.path, file.content);
    }

    const command = buildJavacCommand(files, options);
    const result = await this.exec(command);
    return toCompileResult(result);
  }

  /**
   * Run a compiled Java class inside the container.
   *
   * The class must have been previously compiled with compile().
   * The default classpath is /workspace.
   */
  async run(mainClass: string, args?: string[], options?: RunOptions): Promise<ExecResult> {
    this.assertReady();

    const command = buildJavaCommand(mainClass, args, options);
    const timeoutMs = options?.timeoutMs ?? 120_000;
    return this.exec(command, timeoutMs);
  }

  /**
   * Execute an arbitrary shell command inside the container.
   * Returns captured stdout, stderr, exit code, and execution time.
   *
   * Commands are executed via the script-file mechanism (see process.ts).
   */
  async exec(command: string, timeoutMs = 120_000): Promise<ExecResult> {
    this.assertReady();
    return this.executor.exec(command, timeoutMs);
  }

  // ─── Private: Initialization ─────────────────────────────────────────────

  private async initialize(): Promise<void> {
    this.checkBrowserEnvironment();

    const { config } = this;
    const mode = config.mode ?? 'qemu';

    if (mode === 'direct') {
      await this.initializeDirect();
    } else {
      await this.initializeQemu();
    }
  }

  /**
   * QEMU mode initialization: full container2wasm emulation path.
   * Boots a Linux guest with Alpine + JDK via QEMU TCG in WASM.
   */
  private async initializeQemu(): Promise<void> {
    const { config } = this;
    const networking = config.networking ?? { mode: 'none' };
    validateNetworkConfig(networking);

    // Check relay connectivity before attempting to boot (fast fail)
    if (networking.mode === 'delegate') {
      config.onProgress?.('Checking relay connectivity...', 5);
      const reachable = await checkRelayConnectivity(networking.relayUrl);
      if (!reachable) {
        throw new JavaBoxError(
          `Relay server unreachable at ${networking.relayUrl}`,
          'RELAY_UNREACHABLE',
          'Ensure the c2w-net relay is running. See packages/relay/ for setup.',
        );
      }
    }

    config.onProgress?.('Loading Emscripten module...', 10);

    // Set up PTY for connecting xterm.js to the container (if terminal element provided)
    this.pty = await this.setupPty(config.terminalElement);

    // Configure and load the Emscripten module
    this.module = await this.loadEmscriptenModule(networking);

    config.onProgress?.('Waiting for Linux to boot...', 50);

    // Wait for the guest to finish booting
    const bootTimeout = config.bootTimeoutMs ?? 120_000;
    await this.waitForBoot(bootTimeout);

    // Initialize the filesystem abstraction
    this._fs = new EmscriptenVirtualFS(this.module, EMSCRIPTEN_WORKSPACE_PATH);

    // Initialize the command executor
    this.executor = new ScriptExecutor(this.module, this.pty, EMSCRIPTEN_WORKSPACE_PATH);

    // Ensure the .javabox scratch directory exists
    await this._fs.mkdir('.javabox', true);

    config.onProgress?.('Container ready', 100);
    this._ready = true;
    config.onReady?.();
  }

  /**
   * Direct WASM mode initialization.
   * The JVM runs as a directly-compiled WASM module (no QEMU, no Linux guest).
   * Uses MEMFS for filesystem and jvm_stdin_write() for stdin.
   * Much faster boot (~2-5s vs 20-55s for QEMU mode).
   */
  private async initializeDirect(): Promise<void> {
    const { config } = this;

    config.onProgress?.('Loading direct WASM module...', 10);

    // Set up PTY (still used for terminal display if element provided)
    this.pty = await this.setupPty(config.terminalElement);

    // Load the direct WASM module (same Emscripten loader but different binary)
    const networking = config.networking ?? { mode: 'none' };
    this.module = await this.loadEmscriptenModule(networking);

    config.onProgress?.('Waiting for JVM to initialize...', 50);

    // In direct mode, boot is fast — the JVM starts without a full OS boot.
    // Wait for the CompileServer's JBOX_PONG or a ready sentinel.
    const bootTimeout = config.bootTimeoutMs ?? 30_000; // shorter default for direct
    await this.waitForDirectBoot(bootTimeout);

    // Initialize filesystem with MEMFS path (no virtio-9p mapping needed)
    this._fs = new EmscriptenVirtualFS(this.module, DIRECT_WORKSPACE_PATH);

    // Initialize command executor with direct mode support
    this.executor = new ScriptExecutor(this.module, this.pty, DIRECT_WORKSPACE_PATH);

    // Ensure the .javabox scratch directory exists
    await this._fs.mkdir('.javabox', true);

    config.onProgress?.('Container ready', 100);
    this._ready = true;
    config.onReady?.();
  }

  private checkBrowserEnvironment(): void {
    if (typeof SharedArrayBuffer === 'undefined') {
      throw new JavaBoxError(
        'SharedArrayBuffer is not available',
        'SAB_UNAVAILABLE',
        'Your server must send Cross-Origin-Opener-Policy: same-origin and ' +
        'Cross-Origin-Embedder-Policy: require-corp headers. See web/server-headers.conf.',
      );
    }
  }

  private async setupPty(terminalElement?: HTMLElement): Promise<PtyInterface> {
    // TODO: Integrate with xterm-pty when the terminal element is provided.
    // xterm-pty creates a PTY pair; the 'slave' end connects to the Emscripten
    // Module's stdin/stdout, and the 'master' end connects to xterm.js.
    //
    // When no terminal element is provided, we still need a PTY for sending
    // commands — use a headless PTY that buffers output for exec() to consume.
    //
    // Reference: https://github.com/mame/xterm-pty
    //
    // Pseudocode:
    //   if (terminalElement) {
    //     const terminal = new Terminal({ ... });
    //     terminal.open(terminalElement);
    //     const { master, slave } = openpty();
    //     terminal.loadAddon(master);
    //     return slave;  // slave.write() sends to guest; slave.onData() receives from guest
    //   } else {
    //     const { master, slave } = openpty();
    //     return slave;
    //   }

    // Stub implementation — replace with real xterm-pty integration in Phase 1
    const outputBuffer: string[] = [];
    const dataCallbacks: Array<(data: string) => void> = [];

    return {
      write(data: string | Uint8Array) {
        // TODO: connect to Emscripten Module stdin
        console.debug('[PTY write]', typeof data === 'string' ? data : `<${data.length} bytes>`);
      },
      onData(callback: (data: string) => void) {
        dataCallbacks.push(callback);
        // Replay any buffered data
        for (const chunk of outputBuffer) {
          callback(chunk);
        }
      },
    };
  }

  private async loadEmscriptenModule(networking: typeof this.config.networking): Promise<EmscriptenModule> {
    const { config } = this;
    const wasmBase = config.wasmBaseUrl.endsWith('/')
      ? config.wasmBaseUrl
      : config.wasmBaseUrl + '/';

    // Build the network query param (passed to container2wasm via URL or Module config)
    const netParam = buildNetQueryParam(networking ?? { mode: 'none' });

    // TODO: Determine how container2wasm's out.js reads the network mode.
    // Options:
    //   A) It reads window.location.search for ?net=...
    //   B) It reads a global variable set before the script loads
    //   C) It reads Module.arguments or Module.locateFile options
    //
    // Study the actual out.js generated by c2w to determine which approach to use.
    // For now, we inject the net param into the URL if using delegate mode.

    // Configure the global Module object before loading out.js
    // (Emscripten reads Module before onRuntimeInitialized)
    const moduleConfig: Partial<EmscriptenModule> & Record<string, unknown> = {
      INITIAL_MEMORY: 512 * 1024 * 1024,    // 512MB
      MAXIMUM_MEMORY: 4096 * 1024 * 1024,   // 4GB
      ALLOW_MEMORY_GROWTH: true,

      locateFile: (path: string) => wasmBase + path,

      onRuntimeInitialized: () => {
        config.onProgress?.('QEMU emulator initialized', 70);
      },
    };

    // Merge the module config with xterm-pty's slave once it's available
    // (this.pty is set up in setupPty before this call)
    // TODO: Connect this.pty to Module.stdin/stdout/stderr here.

    // Expose net param for out.js (if it reads a global)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const win = window as any;
    if (netParam) {
      win['c2wNetMode'] = netParam;
    }

    // Inject Module config into global scope (Emscripten non-MODULARIZE build)
    win['Module'] = moduleConfig;

    // Load the c2w-generated Emscripten JS loader
    await this.loadScript(wasmBase + 'out.js');

    // At this point, window.Module has been enriched by out.js with FS, asm, etc.
    const module = win['Module'] as EmscriptenModule;

    // Wait for Module.ready promise if the build uses MODULARIZE=1
    if (module.ready) {
      await module.ready;
    }

    config.onProgress?.('WASM module loaded', 80);
    return module;
  }

  private loadScript(url: string): Promise<void> {
    return new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = url;
      script.onload = () => resolve();
      script.onerror = () =>
        reject(
          new JavaBoxError(
            `Failed to load WASM loader from ${url}`,
            'WASM_LOAD_FAILED',
            'Ensure the WASM files are served from wasmBaseUrl and COOP/COEP headers are set.',
          ),
        );
      document.head.appendChild(script);
    });
  }

  private async waitForBoot(timeoutMs: number): Promise<void> {
    // The container writes a sentinel file at /workspace/.javabox/.ready
    // when the shell profile runs (see container/Dockerfile).
    // We poll the Emscripten FS for this file to detect boot completion.
    //
    // Emscripten FS side path:
    const sentinelPath = `${EMSCRIPTEN_WORKSPACE_PATH}/.javabox/.ready`;

    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        const fs = this.module.FS;
        if (fs && fs.analyzePath(sentinelPath).exists) {
          return; // Boot complete
        }
      } catch {
        // FS not initialized yet
      }
      await sleep(1000);
    }

    // Boot sentinel not found — warn but don't fail hard
    // The container might still be usable if the sentinel setup failed
    console.warn(
      'JavaBox: boot sentinel not detected after', timeoutMs, 'ms. ' +
      'Container may still be starting up. Check that /etc/profile.d/javabox-ready.sh ' +
      'is executing inside the guest.',
    );
  }

  /**
   * Wait for direct WASM mode boot.
   * In direct mode, the JVM starts immediately without a full Linux boot.
   * We detect readiness by polling for a MEMFS sentinel or checking if the
   * Module's exports include jvm_stdin_write (indicating the JVM is ready).
   */
  private async waitForDirectBoot(timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;

    while (Date.now() < deadline) {
      try {
        // Check if the WASM module exports jvm_stdin_write (JVM is initialized)
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const mod = this.module as any;
        if (typeof mod._jvm_stdin_write === 'function' || typeof mod.jvm_stdin_write === 'function') {
          return; // JVM is ready to accept input
        }

        // Alternative: check for MEMFS sentinel file
        const fs = this.module.FS;
        if (fs) {
          try {
            const sentinelPath = `${DIRECT_WORKSPACE_PATH}/.javabox/.ready`;
            if (fs.analyzePath(sentinelPath).exists) {
              return;
            }
          } catch {
            // FS ready but sentinel not yet written
          }
        }
      } catch {
        // Module not initialized yet
      }
      await sleep(200);
    }

    // Direct boot should be fast — warn if it takes too long
    console.warn(
      'JavaBox: direct mode boot not detected after', timeoutMs, 'ms. ' +
      'The JVM WASM module may still be initializing.',
    );
  }

  private assertReady(): void {
    if (!this._ready) {
      throw new Error('JavaContainer is not ready. Await JavaContainer.boot() first.');
    }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
