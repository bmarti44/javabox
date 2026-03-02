// @ts-check
const { test, expect } = require('@playwright/test');

// End-to-end test: boot WASM VM, wait for JShell, compile Hello World,
// verify output. This is a long-running test (~5-15 min depending on hardware).
test.describe('E2E: Compile and Run Java', () => {

  test('compile HelloWorld and see output', async ({ page }) => {
    test.setTimeout(1200000); // 20 min max

    // Collect console logs for diagnostics
    const logs = [];
    page.on('console', msg => {
      const text = msg.text();
      logs.push(text);
      // Print boot/compile progress to test output
      if (text.includes('[BOOT]') || text.includes('[MONITOR]') || text.includes('[COMPILE]') ||
          text.includes('[ISO]') || text.includes('[MINI-INIT]') || text.includes('[COLD-BOOT]')) {
        console.log(text);
      }
    });

    // Navigate and wait for initial page load
    await page.goto('http://localhost:3999/', { waitUntil: 'domcontentloaded' });
    console.log('[TEST] Page loaded, waiting for WASM boot...');

    // Wait for boot phase to reach 'ready' (JShell prompt detected)
    // Poll every 10s, up to 15 min
    await expect.poll(
      () => page.evaluate(() => window._bootPhase),
      {
        message: 'Waiting for JShell to become ready (_bootPhase === "ready")',
        timeout: 900000, // 15 min
        intervals: [10000], // check every 10s
      }
    ).toBe('ready');

    const bootBytes = await page.evaluate(() => window._ptyTotalBytes);
    console.log('[TEST] JShell ready! PTY bytes=' + bootBytes);

    // Verify compile button is enabled
    await expect(page.locator('#compile-run')).toBeEnabled();
    const btnText = await page.locator('#compile-run').textContent();
    expect(btnText).toContain('Compile & Run');

    // Click compile
    console.log('[TEST] Clicking Compile & Run...');
    await page.locator('#compile-run').click();

    // Wait for JBOX_DONE sentinel (compilation complete)
    await expect.poll(
      () => page.evaluate(() => window._ptyRecentText),
      {
        message: 'Waiting for JBOX_DONE sentinel in PTY output',
        timeout: 300000, // 5 min for first compile
        intervals: [5000],
      }
    ).toContain('JBOX_DONE');

    console.log('[TEST] JBOX_DONE detected — compilation succeeded!');

    // Verify "Hello, World!" appeared in PTY output
    const ptyText = await page.evaluate(() => window._ptyRecentText);
    expect(ptyText).toContain('Hello, World!');
    console.log('[TEST] "Hello, World!" found in output');

    // Verify status returned to ready
    await expect(page.locator('#status')).toHaveText('Done');
    await expect(page.locator('#compile-run')).toBeEnabled();
  });
});
