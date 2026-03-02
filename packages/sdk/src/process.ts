/**
 * process.ts — Command execution over the container's PTY/serial interface.
 *
 * container2wasm exposes the guest shell via a virtual serial port (PTY).
 * This module provides the low-level mechanism for sending commands and
 * receiving their output.
 *
 * TWO STRATEGIES (to be validated against the actual c2w output in Phase 1):
 *
 * Strategy A — Script-file execution (preferred):
 *   1. Write a shell script to the shared FS (visible to guest via virtio-9p)
 *   2. Send a command via PTY to source/execute the script
 *   3. Script redirects stdout/stderr to output files on shared FS
 *   4. Script writes exit code to a sentinel file
 *   5. JS polls for the sentinel file via Emscripten FS
 *   6. JS reads output files and returns structured result
 *
 *   Advantages: Reliable, no PTY escape code parsing, structured output
 *   Risk: virtio-9p writes from Emscripten FS side may have sync delay
 *
 * Strategy B — PTY sentinel parsing (fallback):
 *   1. Send command with a unique sentinel string appended
 *   2. Monitor PTY output buffer for the sentinel
 *   3. Parse exit code from the sentinel line
 *
 *   Advantages: Works even if virtio-9p write-from-JS is unreliable
 *   Risk: Terminal escape codes, line wrapping, interleaved output
 *
 * Implementation note:
 *   The exact PTY API depends on container2wasm's JS integration. Study
 *   xterm-pty's API (https://github.com/mame/xterm-pty) and the c2w
 *   emscripten example to determine how to hook into PTY input/output.
 */

import type { EmscriptenFS, EmscriptenModule } from './filesystem';

export interface PtyInterface {
  /** Write bytes to the PTY (sent to guest stdin) */
  write(data: string | Uint8Array): void;
  /** Register a callback for bytes received from guest stdout/stderr */
  onData(callback: (data: string) => void): void;
}

/**
 * Script-based command executor (Strategy A).
 *
 * Writes a runner script to the shared FS, triggers its execution via PTY,
 * then polls for output files on the Emscripten FS side.
 */
export class ScriptExecutor {
  private readonly fs: EmscriptenFS;
  private readonly pty: PtyInterface;
  /** Emscripten-side path to the .javabox scratch directory */
  private readonly scratchBasePath: string;

  constructor(module: EmscriptenModule, pty: PtyInterface, emscriptenBasePath: string) {
    this.fs = module.FS;
    this.pty = pty;
    // e.g., /share/workspace/.javabox  (Emscripten FS side of /workspace/.javabox)
    this.scratchBasePath = `${emscriptenBasePath}/.javabox`;
  }

  /**
   * Execute a shell command inside the container.
   * Returns structured stdout, stderr, exit code, and timing.
   *
   * @param command  The shell command to run (passed to bash -c)
   * @param timeoutMs  Milliseconds to wait before throwing EXEC_TIMEOUT
   */
  async exec(command: string, timeoutMs = 120_000): Promise<ExecOutput> {
    const id = this.generateId();
    const guestScratch = '/workspace/.javabox';

    // Paths as seen from the guest (bash)
    const scriptPath   = `${guestScratch}/run-${id}.sh`;
    const stdoutPath   = `${guestScratch}/out-${id}.txt`;
    const stderrPath   = `${guestScratch}/err-${id}.txt`;
    const exitCodePath = `${guestScratch}/exit-${id}.txt`;

    // Paths as seen from Emscripten FS (JS)
    const emScratch    = this.scratchBasePath;
    const emStdout     = `${emScratch}/out-${id}.txt`;
    const emStderr     = `${emScratch}/err-${id}.txt`;
    const emExit       = `${emScratch}/exit-${id}.txt`;
    const emScript     = `${emScratch}/run-${id}.sh`;

    // Ensure the scratch directory exists on the Emscripten FS side
    this.mkdirIfMissing(emScratch);

    // Write the runner script via Emscripten FS
    // The guest will see this file at /workspace/.javabox/run-<id>.sh
    const script = [
      '#!/bin/bash',
      `${command} >"${stdoutPath}" 2>"${stderrPath}"`,
      `echo $? >"${exitCodePath}"`,
    ].join('\n') + '\n';

    this.fs.writeFile(emScript, script);

    const start = performance.now();

    // Trigger execution by sending the command to PTY (guest shell)
    this.pty.write(`bash "${scriptPath}"\n`);

    // Poll Emscripten FS for the exit code sentinel file
    const exitCodeStr = await this.pollForFile(emExit, timeoutMs);
    const durationMs = performance.now() - start;

    // Read output files
    let stdout = '';
    let stderr = '';
    try { stdout = this.fs.readFile(emStdout, { encoding: 'utf8' }) as string; } catch { /* empty */ }
    try { stderr = this.fs.readFile(emStderr, { encoding: 'utf8' }) as string; } catch { /* empty */ }

    // Clean up scratch files
    this.cleanup([emScript, emStdout, emStderr, emExit]);

    return {
      exitCode: parseInt(exitCodeStr.trim(), 10),
      stdout,
      stderr,
      durationMs,
    };
  }

  private async pollForFile(emPath: string, timeoutMs: number): Promise<string> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        const analysis = this.fs.analyzePath(emPath);
        if (analysis.exists) {
          // Small delay to ensure the guest has finished writing
          await sleep(50);
          return this.fs.readFile(emPath, { encoding: 'utf8' }) as string;
        }
      } catch {
        // FS not ready yet — keep polling
      }
      await sleep(200);
    }
    throw new Error(`exec timed out after ${timeoutMs}ms`);
  }

  private mkdirIfMissing(path: string): void {
    try {
      this.fs.stat(path);
    } catch {
      // Create parents then the directory
      const parts = path.split('/').filter(Boolean);
      let current = '';
      for (const part of parts) {
        current += '/' + part;
        try { this.fs.stat(current); } catch {
          try { this.fs.mkdir(current); } catch { /* already exists */ }
        }
      }
    }
  }

  private cleanup(paths: string[]): void {
    for (const p of paths) {
      try { this.fs.unlink(p); } catch { /* ignore */ }
    }
  }

  private generateId(): string {
    return crypto.randomUUID().replace(/-/g, '').slice(0, 12);
  }
}

/**
 * PTY-sentinel command executor (Strategy B, fallback).
 *
 * Sends a command with a unique sentinel marker and parses the exit code
 * from the PTY output stream. Less reliable than ScriptExecutor but works
 * even when Emscripten FS writes are not immediately visible to the guest.
 *
 * TODO: Implement if ScriptExecutor is not viable after Phase 0 testing.
 */
export class PtySentinelExecutor {
  constructor(_pty: PtyInterface) {
    // Implementation deferred to Phase 1 — depends on xterm-pty API details
  }

  async exec(_command: string, _timeoutMs?: number): Promise<ExecOutput> {
    throw new Error(
      'PtySentinelExecutor not yet implemented. ' +
      'Use ScriptExecutor (Strategy A) or implement PTY output parsing.',
    );
  }
}

export interface ExecOutput {
  exitCode: number;
  stdout: string;
  stderr: string;
  durationMs: number;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
