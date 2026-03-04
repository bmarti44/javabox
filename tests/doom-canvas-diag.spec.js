// @ts-check
const { test, expect } = require('@playwright/test');

// Helper: wait for PTY output to contain a string
async function waitForOutput(page, needle, timeoutMs = 240000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const text = await page.evaluate(() => window._ptyRecentText || '');
    if (text.includes(needle)) return true;
    await page.waitForTimeout(1000);
  }
  return false;
}

// Helper: check canvas state
async function getCanvasDiag(page) {
  return page.evaluate(() => {
    const result = {
      doomActive: !!window.doomActive,
      bootPhase: window._bootPhase || 'unknown',
      frameSeq: -1,
      framePtr: -1,
      frameW: -1,
      frameH: -1,
      canvasHasContent: false,
      nonBlackPixels: 0,
      sampledPixels: 0,
      renderCount: window._doomRenderCount || 0,
    };

    // Access Module via window (exposed globally by doom.html)
    const M = window.Module;
    if (M) {
      try {
        if (M._jvm_doom_frame_seq) result.frameSeq = M._jvm_doom_frame_seq();
        if (M._jvm_doom_frame_ptr) result.framePtr = M._jvm_doom_frame_ptr();
        if (M._jvm_doom_frame_width) result.frameW = M._jvm_doom_frame_width();
        if (M._jvm_doom_frame_height) result.frameH = M._jvm_doom_frame_height();
      } catch (e) { /* Module not ready yet */ }
    }

    const canvas = document.getElementById('doom-canvas');
    if (canvas && canvas.width > 0 && canvas.height > 0) {
      const ctx = canvas.getContext('2d');
      const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
      const pixels = imageData.data;
      let nonBlack = 0;
      const step = 400;
      for (let p = 0; p < pixels.length; p += step) {
        if (pixels[p] > 0 || pixels[p+1] > 0 || pixels[p+2] > 0) nonBlack++;
      }
      result.sampledPixels = Math.floor(pixels.length / step);
      result.nonBlackPixels = nonBlack;
      result.canvasHasContent = nonBlack > 10;
    }

    return result;
  });
}

test('canvas renders on load and reload', async ({ page }) => {
  test.setTimeout(600000); // 10 minutes total

  page.on('console', msg => {
    const text = msg.text();
    if (text.includes('DoomLoop') || text.includes('CanvasRenderer') ||
        text.includes('CRASHED') || text.includes('JBOX_DOOM_START') ||
        text.includes('diag') || text.includes('First frame') ||
        text.includes('S_Init') || text.includes('WebAudio') ||
        text.includes('setupLoop') || text.includes('abort') ||
        text.includes('InputThread') || text.includes('Exception') ||
        text.includes('NullPointer') || text.includes('[PAGE_ERROR]')) {
      console.log('[BROWSER]', text);
    }
  });
  page.on('pageerror', err => console.log('[PAGE_ERROR]', err.message));

  for (let load = 1; load <= 5; load++) {
    console.log(`\n=== LOAD ${load}/5 ===`);

    if (load === 1) {
      await page.goto('http://localhost:3999/doom.html', { waitUntil: 'domcontentloaded' });
    } else {
      await page.reload({ waitUntil: 'domcontentloaded' });
    }

    // Wait for JBOX_DOOM_START (up to 4 minutes - R_Init is slow)
    console.log(`[L${load}] Waiting for JBOX_DOOM_START...`);
    const started = await waitForOutput(page, 'JBOX_DOOM_START', 240000);
    if (!started) {
      console.log(`[L${load}] DOOM never started within 4 minutes`);
      const tail = await page.evaluate(() => (window._ptyRecentText || '').slice(-500));
      console.log(`[L${load}] Last output: ${tail}`);
      expect(started).toBe(true); // Fail with diagnostic
      continue;
    }
    console.log(`[L${load}] JBOX_DOOM_START detected`);

    // Now wait up to 30 seconds for frames to appear
    let gotFrame = false;
    for (let i = 0; i < 30; i++) {
      await page.waitForTimeout(1000);
      const diag = await getCanvasDiag(page);
      console.log(`[L${load}:t=${i+1}s] seq=${diag.frameSeq} ptr=${diag.framePtr} ${diag.frameW}x${diag.frameH} nonBlack=${diag.nonBlackPixels}/${diag.sampledPixels} renders=${diag.renderCount} active=${diag.doomActive} phase=${diag.bootPhase}`);

      // Require frameSeq > 0 (JVM is producing frames) AND canvas has visible content
      if (diag.frameSeq > 0 && diag.canvasHasContent) {
        gotFrame = true;
        console.log(`[L${load}] Canvas is rendering! (seq=${diag.frameSeq}, nonBlack=${diag.nonBlackPixels})`);
        break;
      }
      // Detect black screen: frameSeq > 0 but canvas is black means render loop died
      if (diag.frameSeq > 0 && !diag.canvasHasContent) {
        console.warn(`[L${load}] RENDER LOOP DEAD? frameSeq=${diag.frameSeq} but canvas is black!`);
      }
      // Detect stuck game: canvas might have stale content but no new frames
      if (diag.frameSeq <= 0 && i >= 5) {
        console.warn(`[L${load}] NO FRAMES from JVM after ${i+1}s — setupLoop may have crashed`);
      }
    }

    if (!gotFrame) {
      console.log(`[L${load}] BLACK SCREEN — no frames after 30s`);
      await page.screenshot({ path: `tests/screenshots/doom-black-L${load}.png`, fullPage: true });

      // Extra diagnostics: dump recent JVM output
      const tail = await page.evaluate(() => (window._ptyRecentText || '').slice(-1000));
      console.log(`[L${load}] JVM output tail:\n${tail}`);
    }

    expect(gotFrame).toBe(true);

    // Wait a bit before reload
    await page.waitForTimeout(3000);
  }
});
