/**
 * @javabox/sdk — Run Java in the browser via Oracle Linux + JDK 21 in WASM
 *
 * Quick start:
 *
 *   import { JavaContainer } from '@javabox/sdk';
 *
 *   const container = await JavaContainer.boot({
 *     wasmBaseUrl: 'https://cdn.javabox.dev/v0.1.0/',
 *     networking: { mode: 'browser' },
 *     onProgress: (stage, pct) => console.log(stage, pct),
 *   });
 *
 *   const result = await container.compile([
 *     { path: 'Hello.java', content: 'public class Hello { ... }' }
 *   ]);
 *
 *   const run = await container.run('Hello');
 *   console.log(run.stdout);
 */

export { JavaContainer } from './container';
export type {
  JavaContainerConfig,
  ExecResult,
  CompileResult,
  CompileError,
  SourceFile,
  CompileOptions,
  RunOptions,
  VirtualFS,
  JavaBoxErrorCode,
} from './types';
export { JavaBoxError } from './types';
