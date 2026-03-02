/** Configuration for booting the Java container */
export interface JavaContainerConfig {
  /** URL to the directory containing the c2w --to-js output files */
  wasmBaseUrl: string;

  /** Networking mode */
  networking?:
    | { mode: 'browser' }                              // HTTP/S only via browser Fetch API (c2w-net-proxy)
    | { mode: 'delegate'; relayUrl: string }            // Full TCP/UDP via c2w-net relay server
    | { mode: 'none' };                                 // No networking (default if omitted)

  /** Called when container writes to stdout (raw bytes, not line-buffered) */
  onStdout?: (data: string) => void;

  /** Called when container writes to stderr (raw bytes, not line-buffered) */
  onStderr?: (data: string) => void;

  /** Called when container is ready to accept commands (boot sentinel detected) */
  onReady?: () => void;

  /** Called during boot to report progress. percent is 0–100 if known, else undefined. */
  onProgress?: (stage: string, percent?: number) => void;

  /**
   * DOM element to attach an xterm.js terminal to (optional).
   * When provided, the container's console is connected to an interactive terminal.
   * When omitted, all I/O goes through onStdout/onStderr and the exec() API.
   */
  terminalElement?: HTMLElement;

  /**
   * Maximum time in milliseconds to wait for the container to boot.
   * Defaults to 120000 (2 minutes).
   */
  bootTimeoutMs?: number;
}

/** Result of a compile or run operation */
export interface ExecResult {
  /** Process exit code (0 = success) */
  exitCode: number;
  /** Captured stdout as a string */
  stdout: string;
  /** Captured stderr as a string */
  stderr: string;
  /** Wall-clock execution time in milliseconds */
  durationMs: number;
}

/** Parsed Java compilation diagnostic */
export interface CompileError {
  /** Source file path relative to /workspace (e.g., "com/example/Main.java") */
  file: string;
  /** Line number (1-based) */
  line: number;
  /** Column number (1-based, 0 if not reported) */
  column: number;
  /** Human-readable diagnostic message */
  message: string;
  /** Severity level */
  kind: 'error' | 'warning' | 'note';
}

/** Result of a javac compilation, with structured diagnostics */
export interface CompileResult extends ExecResult {
  /** Parsed compilation errors/warnings/notes */
  diagnostics: CompileError[];
}

/** A Java source file to write into the container */
export interface SourceFile {
  /**
   * Path relative to /workspace inside the container.
   * Examples: "Hello.java", "com/example/Main.java"
   */
  path: string;
  /** File content as a UTF-8 string */
  content: string;
}

/** Compile options for javac */
export interface CompileOptions {
  /** Additional classpath entries (joined with ':') */
  classpath?: string[];
  /** Raw javac flags (e.g., ["-source", "21", "-target", "21"]) */
  flags?: string[];
}

/** Run options for java */
export interface RunOptions {
  /** Additional classpath entries */
  classpath?: string[];
  /** JVM flags (e.g., ["-ea", "-Xmx128m"]) */
  jvmFlags?: string[];
  /** Timeout in milliseconds for the run command */
  timeoutMs?: number;
}

/** Filesystem abstraction over the container's virtio-9p shared volume */
export interface VirtualFS {
  /**
   * Write a file to the container filesystem.
   * Path is relative to /workspace (e.g., "Hello.java" or "com/example/Main.java").
   * Parent directories are created automatically.
   */
  writeFile(path: string, content: string | Uint8Array): Promise<void>;

  /**
   * Read a file from the container filesystem as a UTF-8 string.
   */
  readFile(path: string): Promise<string>;

  /**
   * Read a file from the container filesystem as raw bytes.
   */
  readFileBytes(path: string): Promise<Uint8Array>;

  /**
   * Check whether a path exists in the container filesystem.
   */
  exists(path: string): Promise<boolean>;

  /**
   * Create a directory. If recursive is true, creates parent directories as needed.
   */
  mkdir(path: string, recursive?: boolean): Promise<void>;

  /**
   * Delete a file or directory. If recursive is true, deletes directory contents.
   */
  rm(path: string, recursive?: boolean): Promise<void>;

  /**
   * List directory contents. Returns filenames (not full paths), excluding '.' and '..'.
   */
  ls(path: string): Promise<string[]>;
}

/**
 * Error thrown when JavaBox encounters a fatal condition.
 * The `code` field identifies the failure category for programmatic handling.
 */
export class JavaBoxError extends Error {
  constructor(
    message: string,
    public readonly code: JavaBoxErrorCode,
    public readonly suggestion: string,
  ) {
    super(message);
    this.name = 'JavaBoxError';
  }
}

export type JavaBoxErrorCode =
  | 'COOP_MISSING'       // Cross-Origin-Opener-Policy header not set
  | 'COEP_MISSING'       // Cross-Origin-Embedder-Policy header not set
  | 'SAB_UNAVAILABLE'    // SharedArrayBuffer not available (implies missing headers)
  | 'WASM_LOAD_FAILED'   // Failed to fetch/parse the WASM module
  | 'BOOT_TIMEOUT'       // Container did not become ready within bootTimeoutMs
  | 'RELAY_UNREACHABLE'  // Delegate relay WebSocket connection failed
  | 'EXEC_TIMEOUT'       // A command timed out during execution
  | 'FS_ERROR';          // Filesystem operation failed
