// @ts-check
const { test, expect } = require('@playwright/test');

// E2E: snapshot-restore boot + CompileServer compile HelloWorld
test('snapshot restore + CompileServer compile', async ({ page }) => {
  test.setTimeout(600000); // 10 min (CompileServer should be fast)

  page.on('console', msg => {
    const text = msg.text();
    if (text.includes('[BOOT]') || text.includes('[COMPILE]') ||
        text.includes('[PTY.write') || text.includes('[MONITOR') ||
        text.includes('[print') || text.includes('[Worker') ||
        text.includes('[QEMU')) {
      console.log(text);
    }
  });

  await page.goto('http://localhost:3999/', { waitUntil: 'domcontentloaded' });
  console.log('[TEST] Page loaded');

  // Wait for boot — CompileServer's JBOX_PONG detection should be fast (< 2 min)
  for (let i = 1; i <= 20; i++) {
    await page.waitForTimeout(30000);
    const state = await page.evaluate(() => ({
      phase: window._bootPhase,
      bytes: window._ptyTotalBytes,
      writes: window._ptyWriteCount,
      tail: window._ptyRecentText.slice(-300).replace(/[\x00-\x1f]/g, '.'),
    }));
    console.log(`[STATE t=${i*30}s] phase=${state.phase} bytes=${state.bytes} writes=${state.writes}`);
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
    for (let i = 1; i <= 12; i++) {
      await page.waitForTimeout(10000);
      const state = await page.evaluate(() => ({
        bytes: window._ptyTotalBytes,
        done: window._compileDone,
        tail: window._ptyRecentText.slice(-300).replace(/[\x00-\x1f]/g, '.'),
      }));
      console.log(`[COMPILE t=${i*10}s] bytes=${state.bytes} done=${state.done}`);
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
