/**
 * compiler.ts — javac wrapper with structured error parsing.
 *
 * Builds and parses javac invocations, returning CompileResult with
 * both raw output and structured CompileError diagnostics.
 */

import type { CompileError, CompileResult, ExecResult, SourceFile, CompileOptions } from './types';

/**
 * Build the javac shell command for the given source files and options.
 *
 * @param files    Source files to compile (only .java files are passed to javac)
 * @param options  javac options: classpath, raw flags
 * @returns        Shell command string (to be executed via exec())
 */
export function buildJavacCommand(files: SourceFile[], options?: CompileOptions): string {
  const javaFiles = files
    .filter((f) => f.path.endsWith('.java'))
    .map((f) => `/workspace/${f.path.startsWith('/') ? f.path.slice(1) : f.path}`);

  if (javaFiles.length === 0) {
    throw new Error('No .java files provided to compile');
  }

  const cp = options?.classpath?.length ? options.classpath.join(':') : '/workspace';
  const flags = options?.flags?.join(' ') ?? '';

  // Redirect stderr to stdout so both are captured in a single stream.
  // The exit code is captured via the script-file execution mechanism.
  return `javac -cp "${cp}" ${flags} ${javaFiles.map((f) => `"${f}"`).join(' ')} 2>&1`;
}

/**
 * Parse javac output into structured CompileError diagnostics.
 *
 * javac output format:
 *   /workspace/com/example/Main.java:15: error: ';' expected
 *       System.out.println("hello")
 *                                  ^
 *   1 error
 *
 * Notes:
 *   - Column number appears on the pointer line (^) but not the message line
 *   - We extract column by counting characters before '^' on the pointer line
 *   - 'note' diagnostics are informational (e.g., "uses unchecked operations")
 */
export function parseJavacOutput(output: string): CompileError[] {
  const diagnostics: CompileError[] = [];
  const lines = output.split('\n');

  // Pattern: /path/to/File.java:LINE: KIND: MESSAGE
  const headerRe = /^(.+\.java):(\d+): (error|warning|note): (.+)$/;
  // Pattern: the pointer line (spaces + ^)
  const pointerRe = /^(\s*)\^/;

  let i = 0;
  while (i < lines.length) {
    const headerMatch = headerRe.exec(lines[i]);
    if (headerMatch) {
      const rawFile = headerMatch[1];
      const lineNum = parseInt(headerMatch[2], 10);
      const kind = headerMatch[3] as 'error' | 'warning' | 'note';
      const message = headerMatch[4];

      // Normalize file path: strip /workspace/ prefix
      const file = rawFile.replace(/^\/workspace\//, '');

      // Look ahead for the source line and pointer line to get column
      let column = 0;
      let j = i + 1;
      while (j < lines.length && j < i + 4) {
        const pointerMatch = pointerRe.exec(lines[j]);
        if (pointerMatch) {
          column = pointerMatch[1].length + 1; // 1-based
          break;
        }
        j++;
      }

      diagnostics.push({ file, line: lineNum, column, message, kind });
    }
    i++;
  }

  return diagnostics;
}

/**
 * Combine a raw ExecResult with parsed diagnostics into a CompileResult.
 */
export function toCompileResult(result: ExecResult): CompileResult {
  const combined = result.stdout + '\n' + result.stderr;
  const diagnostics = parseJavacOutput(combined);
  return { ...result, diagnostics };
}
