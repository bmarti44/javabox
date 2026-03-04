// @ts-check
const { test, expect } = require('@playwright/test');

test.describe('E2E: Compile and Run Java', () => {

  test('compile HelloWorld and see output', async ({ page }) => {
    test.setTimeout(120000);

    page.on('console', msg => {
      const text = msg.text();
      if (text.includes('[BOOT]') || text.includes('[COMPILE]') || text.includes('[JavaBox]')) {
        console.log(text);
      }
    });

    await page.goto('http://localhost:3999/', { waitUntil: 'domcontentloaded' });
    console.log('[TEST] Page loaded, waiting for JVM boot...');

    // Wait for boot phase to reach 'ready'
    await expect.poll(
      () => page.evaluate(() => window._bootPhase),
      {
        message: 'Waiting for CompileServer to become ready (_bootPhase === "ready")',
        timeout: 60000,
        intervals: [2000],
      }
    ).toBe('ready');

    console.log('[TEST] CompileServer ready!');

    // Verify compile button is enabled
    await expect(page.locator('#compile-run')).toBeEnabled();

    // Verify editor has default code
    const editorContent = await page.locator('#code-editor').inputValue();
    expect(editorContent).toContain('public class HelloWorld');
    expect(editorContent).toContain('System.out.println');

    // Click compile
    console.log('[TEST] Clicking Compile & Run...');
    await page.locator('#compile-run').click();

    // Wait for JBOX_EXIT in output
    await expect.poll(
      () => page.evaluate(() => window._ptyRecentText),
      {
        message: 'Waiting for JBOX_EXIT in output',
        timeout: 60000,
        intervals: [2000],
      }
    ).toContain('JBOX_EXIT:0');

    console.log('[TEST] JBOX_EXIT:0 detected!');

    // Verify "Hello, World!" appeared in output
    const ptyText = await page.evaluate(() => window._ptyRecentText);
    expect(ptyText).toContain('Hello, World!');
    console.log('[TEST] "Hello, World!" found in output');

    // Verify status returned to ready
    await expect(page.locator('#status')).toHaveText('Done');
    await expect(page.locator('#compile-run')).toBeEnabled();
  });
});
