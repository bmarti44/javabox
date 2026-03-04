// @ts-check
const { test, expect } = require('@playwright/test');

test('doom diagnostic — check DoomLoop and frame buffer', async ({ page }) => {
  test.setTimeout(300000);

  // Capture ALL console output
  const allLogs = [];
  page.on('console', msg => {
    const text = msg.text();
    allLogs.push(text);
    // Log everything from JVM
    if (text.includes('[JVM') || text.includes('[DOOM]') || text.includes('JBOX_') ||
        text.includes('abort') || text.includes('Error') || text.includes('Crash') ||
        text.includes('DoomLoop') || text.includes('exception') || text.includes('Exception') ||
        text.includes('Null') || text.includes('Unsatisfied')) {
      console.log('[BROWSER]', text);
    }
  });

  page.on('pageerror', err => {
    console.log('[PAGE_ERROR]', err.message);
  });

  await page.goto('http://localhost:3999/doom.html', { waitUntil: 'domcontentloaded' });
  console.log('[TEST] Page loaded');

  // Wait for JBOX_DOOM_START
  let doomStarted = false;
  for (let i = 0; i < 90; i++) {
    await page.waitForTimeout(2000);
    const text = await page.evaluate(() => window._ptyRecentText || '');
    if (text.includes('JBOX_DOOM_START')) {
      doomStarted = true;
      console.log(`[TEST] JBOX_DOOM_START at ${(i+1)*2}s`);
      break;
    }
    if (i % 10 === 0) {
      console.log(`[TEST] Waiting... ${(i+1)*2}s`);
    }
  }

  if (!doomStarted) {
    console.log('[TEST] DOOM did not start');
    const text = await page.evaluate(() => window._ptyRecentText || '');
    console.log('[TEST] Last output:', text.slice(-500));
    return;
  }

  // Now check frame buffer state every 5 seconds for 60 seconds
  for (let i = 0; i < 12; i++) {
    await page.waitForTimeout(5000);
    const frameState = await page.evaluate(() => {
      const result = {
        seq: 0,
        ptr: 0,
        width: 0,
        height: 0,
        allJvmOutput: (window._ptyRecentText || '').slice(-2000),
      };
      if (typeof Module !== 'undefined') {
        try {
          result.seq = Module._jvm_doom_frame_seq();
          result.ptr = Module._jvm_doom_frame_ptr();
          result.width = Module._jvm_doom_frame_width();
          result.height = Module._jvm_doom_frame_height();
        } catch (e) {
          result.error = e.message;
        }
      }
      return result;
    });

    console.log(`[FRAME t=${(i+1)*5}s] seq=${frameState.seq} ptr=${frameState.ptr} size=${frameState.width}x${frameState.height}`);

    // Check for DoomLoop crash in output
    if (frameState.allJvmOutput.includes('DoomLoop') || frameState.allJvmOutput.includes('CRASHED')) {
      console.log('[TEST] DoomLoop crash detected in output!');
      const crashLines = frameState.allJvmOutput.split('\n').filter(l =>
        l.includes('DoomLoop') || l.includes('CRASHED') || l.includes('UEH') ||
        l.includes('Exception') || l.includes('Error'));
      crashLines.forEach(l => console.log('[CRASH]', l));
    }

    if (frameState.error) {
      console.log('[TEST] Frame check error:', frameState.error);
    }

    if (frameState.seq > 0) {
      console.log('[TEST] Frames are being produced! Taking screenshot...');
      await page.screenshot({ path: 'tests/screenshots/doom-diag-frame.png', fullPage: true });

      // Check canvas pixel data
      const pixelCheck = await page.evaluate(() => {
        const canvas = document.getElementById('doom-canvas');
        if (!canvas) return { error: 'no canvas' };
        const ctx = canvas.getContext('2d');
        const data = ctx.getImageData(0, 0, canvas.width, canvas.height);
        let nonBlack = 0;
        for (let i = 0; i < data.data.length; i += 4) {
          if (data.data[i] > 0 || data.data[i+1] > 0 || data.data[i+2] > 0) nonBlack++;
        }
        return { width: canvas.width, height: canvas.height, nonBlack, totalPixels: data.data.length / 4 };
      });
      console.log('[PIXELS]', JSON.stringify(pixelCheck));
      break;
    }
  }

  // Final check: dump any DoomLoop-related output
  const finalOutput = await page.evaluate(() => (window._ptyRecentText || '').slice(-3000));
  const doomLoopLines = finalOutput.split('\n').filter(l =>
    l.includes('DoomLoop') || l.includes('CRASHED') || l.includes('UEH') ||
    l.includes('Exception') || l.includes('Unsatisfied') || l.includes('NullPointer'));
  if (doomLoopLines.length > 0) {
    console.log('[TEST] DoomLoop-related output:');
    doomLoopLines.forEach(l => console.log('  ', l));
  } else {
    console.log('[TEST] No DoomLoop crash messages in output');
  }

  // Dump last 500 chars of JVM output for context
  console.log('[TEST] Last JVM output:', finalOutput.slice(-500));
});
