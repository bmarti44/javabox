// @ts-check
const { test, expect } = require('@playwright/test');

// Enable video recording for this test
test.use({
  video: { mode: 'on', size: { width: 1280, height: 720 } },
  viewport: { width: 1280, height: 720 },
});

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

test('capture Doom screenshots and video for README', async ({ page }) => {
  test.setTimeout(600000);

  await page.goto('http://localhost:3999/doom.html', { waitUntil: 'domcontentloaded' });

  // Screenshot 1: Boot/loading screen
  await page.waitForTimeout(3000);
  await page.screenshot({ path: 'docs/doom-boot.png' });
  console.log('Captured: doom-boot.png');

  // Wait for Doom to start
  console.log('Waiting for JBOX_DOOM_START...');
  const started = await waitForOutput(page, 'JBOX_DOOM_START', 240000);
  expect(started).toBe(true);
  console.log('JBOX_DOOM_START detected');

  // Wait for frames to render
  await page.waitForTimeout(3000);

  // Screenshot 2: Doom title screen (full page)
  await page.screenshot({ path: 'docs/doom-title.png' });
  console.log('Captured: doom-title.png');

  // Screenshot 3: Just the canvas
  const canvas = page.locator('#doom-canvas');
  await canvas.screenshot({ path: 'docs/doom-canvas.png' });
  console.log('Captured: doom-canvas.png');

  // Let it run for ~15 seconds so the video captures the title screen animation
  console.log('Recording video for 15 seconds...');
  await page.waitForTimeout(15000);

  // Final screenshot
  await page.screenshot({ path: 'docs/doom-playing.png' });
  console.log('Captured: doom-playing.png');

  console.log('Done — video will be saved automatically by Playwright');
});
