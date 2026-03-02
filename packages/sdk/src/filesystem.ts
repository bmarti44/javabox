import type { VirtualFS } from './types';

/**
 * Wraps Emscripten's Module.FS API with the virtio-9p mount path mapping.
 *
 * In container2wasm's --to-js mode, the QEMU Wasm virtual machine exposes
 * the guest filesystem to JavaScript via Emscripten FS. The virtio-9p
 * protocol shares a specific Emscripten FS directory with the guest at a
 * configured mount point.
 *
 * PATH MAPPING (verify empirically in Phase 0):
 *   Emscripten FS: /share/workspace/  →  Guest: /workspace/
 *
 * How to verify:
 *   1. Write a file via Module.FS.writeFile('/share/workspace/test.txt', 'hello')
 *   2. In the guest terminal, run: cat /workspace/test.txt
 *   3. If it shows "hello", the mapping is correct.
 *   4. Inspect the generated out.js for -virtfs or -fsdev QEMU flags to confirm.
 */
export class EmscriptenVirtualFS implements VirtualFS {
  private readonly fs: EmscriptenFS;
  /**
   * The Emscripten FS path that maps to the guest's /workspace directory.
   * Determined empirically after running convert.sh and inspecting the output.
   * Placeholder: '/share/workspace' — update after Phase 0 validation.
   */
  private readonly basePath: string;

  constructor(emscriptenModule: EmscriptenModule, basePath: string) {
    this.fs = emscriptenModule.FS;
    this.basePath = basePath.endsWith('/') ? basePath.slice(0, -1) : basePath;
  }

  private resolve(path: string): string {
    // Strip leading slash from relative paths, then join with base
    const clean = path.startsWith('/') ? path.slice(1) : path;
    return `${this.basePath}/${clean}`;
  }

  async writeFile(path: string, content: string | Uint8Array): Promise<void> {
    const fullPath = this.resolve(path);
    const dir = fullPath.substring(0, fullPath.lastIndexOf('/'));
    if (dir && dir !== this.basePath) {
      this.mkdirRecursive(dir);
    }
    this.fs.writeFile(fullPath, content);
  }

  async readFile(path: string): Promise<string> {
    return this.fs.readFile(this.resolve(path), { encoding: 'utf8' }) as string;
  }

  async readFileBytes(path: string): Promise<Uint8Array> {
    return this.fs.readFile(this.resolve(path)) as Uint8Array;
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
      this.rmRecursive(fullPath);
    } else {
      this.fs.unlink(fullPath);
    }
  }

  async ls(path: string): Promise<string[]> {
    return (this.fs.readdir(this.resolve(path)) as string[])
      .filter((name) => name !== '.' && name !== '..');
  }

  private mkdirRecursive(path: string): void {
    const parts = path.split('/').filter(Boolean);
    let current = '';
    for (const part of parts) {
      current += '/' + part;
      try {
        this.fs.stat(current);
      } catch {
        try {
          this.fs.mkdir(current);
        } catch {
          // Race condition or already exists — ignore
        }
      }
    }
  }

  private rmRecursive(path: string): void {
    try {
      const stat = this.fs.stat(path);
      if (this.fs.isDir(stat.mode)) {
        const entries = (this.fs.readdir(path) as string[])
          .filter((n) => n !== '.' && n !== '..');
        for (const entry of entries) {
          this.rmRecursive(`${path}/${entry}`);
        }
        this.fs.rmdir(path);
      } else {
        this.fs.unlink(path);
      }
    } catch {
      // Path doesn't exist — ignore
    }
  }
}

// ─── Minimal Emscripten type stubs ───────────────────────────────────────────
// These are the parts of the Emscripten Module and FS API we use.
// The full type definitions are complex; we only declare what we need.

export interface EmscriptenModule {
  FS: EmscriptenFS;
  ready?: Promise<void>;
  INITIAL_MEMORY?: number;
  MAXIMUM_MEMORY?: number;
  ALLOW_MEMORY_GROWTH?: boolean;
  locateFile?: (path: string, scriptDirectory?: string) => string;
  stdin?: () => number | null;
  stdout?: (char: number) => void;
  stderr?: (char: number) => void;
  onRuntimeInitialized?: () => void;
}

export interface EmscriptenFS {
  writeFile(path: string, data: string | Uint8Array, opts?: { flags?: string }): void;
  readFile(path: string, opts?: { encoding?: 'utf8' | 'binary' }): string | Uint8Array;
  stat(path: string): { mode: number; size: number };
  mkdir(path: string): void;
  rmdir(path: string): void;
  unlink(path: string): void;
  readdir(path: string): string[];
  isDir(mode: number): boolean;
  analyzePath(path: string): { exists: boolean; isRoot: boolean; path: string };
}
