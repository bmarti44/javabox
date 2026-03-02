/**
 * runner.ts — java execution wrapper.
 *
 * Builds the `java` command for running compiled Java classes inside the container.
 */

import type { RunOptions } from './types';

/**
 * Build the java shell command for running a compiled class.
 *
 * @param mainClass  The fully-qualified main class name (e.g., "com.example.Main" or "Hello")
 * @param args       Command-line arguments passed to the Java program's main(String[] args)
 * @param options    JVM options: classpath entries, JVM flags, timeout
 * @returns          Shell command string (to be executed via exec())
 */
export function buildJavaCommand(
  mainClass: string,
  args?: string[],
  options?: RunOptions,
): string {
  const cp = options?.classpath?.length ? options.classpath.join(':') : '/workspace';
  const jvmFlags = options?.jvmFlags?.join(' ') ?? '';
  const argsStr = args?.map((a) => `"${a.replace(/"/g, '\\"')}"`).join(' ') ?? '';

  return `java -cp "${cp}" ${jvmFlags} ${mainClass} ${argsStr} 2>&1`.trim();
}
