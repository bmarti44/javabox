// @ts-check
const { test, expect } = require('@playwright/test');

// These tests verify the JavaBox page structure and boot behavior.
// They run quickly — no full JVM boot required for most tests.

test.describe('JavaBox UI and Boot', () => {

  test('page loads with correct UI structure', async ({ page }) => {
    await page.goto('http://localhost:3999/');

    // Header elements
    await expect(page.locator('#header h1')).toHaveText('JavaBox');
    await expect(page.locator('#status')).toBeVisible();
    await expect(page.locator('#compile-run')).toBeVisible();
    await expect(page.locator('#filename')).toHaveValue('HelloWorld.java');

    // Editor and terminal panels
    await expect(page.locator('#editor-panel')).toBeVisible();
    await expect(page.locator('#terminal-panel')).toBeVisible();
    await expect(page.locator('#code-editor')).toBeVisible();
    await expect(page.locator('#terminal')).toBeVisible();
  });

  test('COOP/COEP headers are present (SharedArrayBuffer available)', async ({ page }) => {
    const response = await page.goto('http://localhost:3999/');
    const headers = response.headers();
    expect(headers['cross-origin-opener-policy']).toBe('same-origin');
    expect(headers['cross-origin-embedder-policy']).toBe('require-corp');
  });

  test('boot phase tracking is initialized', async ({ page }) => {
    await page.goto('http://localhost:3999/');

    const bootState = await page.evaluate(() => ({
      bootPhase: window._bootPhase,
      ptyWriteCount: window._ptyWriteCount,
      ptyTotalBytes: window._ptyTotalBytes,
    }));

    // Boot phase should be 'booting' (module script sets it during init)
    expect(['loading', 'booting']).toContain(bootState.bootPhase);
    expect(bootState.ptyWriteCount).toBe(0);
    expect(bootState.ptyTotalBytes).toBe(0);
  });

  test('compile button is disabled during boot', async ({ page }) => {
    await page.goto('http://localhost:3999/');
    await expect(page.locator('#compile-run')).toBeDisabled();
  });

  test('editor contains default Java code', async ({ page }) => {
    await page.goto('http://localhost:3999/');
    const editorContent = await page.locator('#code-editor').inputValue();
    expect(editorContent).toContain('public class HelloWorld');
    expect(editorContent).toContain('System.out.println');
  });
});
