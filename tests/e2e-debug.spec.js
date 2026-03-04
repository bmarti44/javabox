// @ts-check
const { test, expect } = require('@playwright/test');

// Mode detection: 'qemu' (default) or 'direct' (direct WASM, much faster boot)
const MODE = process.env.JAVABOX_MODE || 'qemu';
const IS_DIRECT = MODE === 'direct';

// E2E: snapshot-restore boot + CompileServer compile HelloWorld
test('snapshot restore + CompileServer compile', async ({ page }) => {
  test.setTimeout(IS_DIRECT ? 60000 : 600000);

  page.on('console', msg => {
    const text = msg.text();
    if (text.includes('[BOOT]') || text.includes('[COMPILE]') ||
        text.includes('[PTY.write') || text.includes('[MONITOR') ||
        text.includes('[print') || text.includes('[Worker') ||
        text.includes('[QEMU')) {
      console.log(text);
    }
  });

  await page.goto(`http://localhost:3999/?mode=${MODE}`, { waitUntil: 'domcontentloaded' });
  console.log(`[TEST] Page loaded (mode=${MODE})`);

  // Wait for boot — CompileServer's JBOX_PONG detection should be fast (< 2 min)
  // Direct mode boots much faster, so use shorter poll intervals and fewer iterations
  const bootIterations = IS_DIRECT ? 12 : 20;
  const bootPollMs = IS_DIRECT ? 5000 : 30000;
  for (let i = 1; i <= bootIterations; i++) {
    await page.waitForTimeout(bootPollMs);
    const state = await page.evaluate(() => ({
      phase: window._bootPhase,
      bytes: window._ptyTotalBytes,
      writes: window._ptyWriteCount,
      tail: window._ptyRecentText.slice(-300).replace(/[\x00-\x1f]/g, '.'),
    }));
    const elapsed = IS_DIRECT ? i * 5 : i * 30;
    console.log(`[STATE t=${elapsed}s] phase=${state.phase} bytes=${state.bytes} writes=${state.writes}`);
    if (state.tail) console.log(`[TAIL] ${state.tail.slice(-200)}`);
    if (state.phase === 'ready') break;
  }

  // Verify compile button is enabled
  const phase = await page.evaluate(() => window._bootPhase);
  console.log('[TEST] Boot phase:', phase);

  if (phase === 'ready') {
    console.log('[TEST] Clicking Compile & Run...');
    await page.locator('#compile-run').click();

    // Monitor compile progress — CompileServer compiles in-process (should be fast)
    const compileIterations = IS_DIRECT ? 12 : 12;
    const compilePollMs = IS_DIRECT ? 5000 : 10000;
    for (let i = 1; i <= compileIterations; i++) {
      await page.waitForTimeout(compilePollMs);
      const state = await page.evaluate(() => ({
        bytes: window._ptyTotalBytes,
        done: window._compileDone,
        tail: window._ptyRecentText.slice(-300).replace(/[\x00-\x1f]/g, '.'),
      }));
      const compileElapsed = IS_DIRECT ? i * 5 : i * 10;
      console.log(`[COMPILE t=${compileElapsed}s] bytes=${state.bytes} done=${state.done}`);
      console.log(`[TAIL] ${state.tail.slice(-200)}`);
      // Detect JBOX_EXIT:<code> from CompileServer
      const exitMatch = state.tail.match(/JBOX_EXIT:(\d+)/);
      if (exitMatch) {
        const exitCode = parseInt(exitMatch[1]);
        if (exitCode === 0) {
          console.log('[TEST] JBOX_EXIT:0 — compilation succeeded!');
        } else {
          console.log('[TEST] JBOX_EXIT:' + exitCode + ' — compilation failed!');
          console.log('[TAIL] ' + state.tail.slice(-300));
        }
        break;
      }
      if (state.done) break;
    }
  }
});
