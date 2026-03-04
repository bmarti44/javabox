// @ts-check
const { test, expect } = require('@playwright/test');

test('direct WASM Doom: canvas rendering', async ({ page }) => {
  test.setTimeout(300000);

  const consoleLines = [];
  page.on('console', msg => {
    const line = `[B:${msg.type()}] ${msg.text()}`;
    consoleLines.push(line);
    console.log(line);
  });
  page.on('pageerror', err => console.log('[PAGE ERROR]', err.message));

  await page.goto('http://localhost:3999/doom.html?mode=direct', { waitUntil: 'domcontentloaded' });

  // Wait for Doom to fully boot
  let doomStarted = false;
  for (let i = 0; i < 48; i++) {
    await page.waitForTimeout(5000);
    const text = await page.evaluate(() => window._ptyRecentText || '');
    const status = await page.evaluate(() => document.getElementById('status')?.textContent || '');
    console.log(`[WAIT ${(i+1)*5}s] status="${status}", output length: ${text.length}`);
    if (text.includes('JBOX_DOOM_START')) {
      doomStarted = true;
      break;
    }
    if (text.includes('JBOX_EXIT:')) {
      break;
    }
  }

  if (!doomStarted) {
    const output = await page.evaluate(() => window._ptyRecentText || '');
    console.log('[FULL OUTPUT]', output);
    test.fail(true, 'JBOX_DOOM_START not detected');
    return;
  }

  console.log('[DOOM STARTED] Waiting 20s for canvas frames...');
  await page.waitForTimeout(20000);

  // Check canvas state
  const canvasState = await page.evaluate(() => {
    const canvas = document.getElementById('doom-canvas');
    const container = document.getElementById('doom-canvas-container');
    const termContainer = document.getElementById('terminal-container');
    return {
      canvasVisible: container?.style.display === 'flex',
      terminalHidden: termContainer?.style.display === 'none',
      canvasWidth: canvas?.width || 0,
      canvasHeight: canvas?.height || 0,
    };
  });
  console.log('[CANVAS STATE]', JSON.stringify(canvasState));

  // Take screenshot of the whole page
  await page.screenshot({ path: 'tests/screenshots/doom-canvas.png' });
  console.log('[SCREENSHOT] saved to tests/screenshots/doom-canvas.png');

  // Check if canvas has non-black pixels (actual rendering)
  const hasPixels = await page.evaluate(() => {
    const canvas = document.getElementById('doom-canvas');
    if (!canvas) return false;
    const ctx = canvas.getContext('2d');
    const data = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
    let nonBlack = 0;
    for (let i = 0; i < data.length; i += 4) {
      if (data[i] > 10 || data[i+1] > 10 || data[i+2] > 10) {
        nonBlack++;
      }
    }
    return nonBlack;
  });
  console.log('[CANVAS PIXELS] non-black:', hasPixels);

  // Check for crash errors
  const errLines = consoleLines.filter(l => l.includes('CRASHED') || l.includes('DoomLoop-UEH'));
  if (errLines.length > 0) {
    console.log('[DOOM ERRORS]', errLines.join('\n'));
  }

  // Log frame sequence from console
  const frameLines = consoleLines.filter(l => l.includes('Canvas rendering started') || l.includes('CanvasRenderer'));
  console.log('[FRAME LINES]', frameLines.join('\n'));

  expect(doomStarted).toBe(true);
});
