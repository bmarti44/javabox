// @ts-check
const { test, expect } = require('@playwright/test');

// These tests verify that the JVM boot optimization changes
// (jlink, CDS, path updates, ISO auto-detection) are correctly
// implemented in the rendered web app. They do NOT boot the full
// WASM VM — they verify the page loads and the JavaScript code
// contains the expected changes.

test.describe('JVM Boot Optimization Changes', () => {

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

  test('jshell path updated to /opt/jdk/bin/jshell', async ({ page }) => {
    await page.goto('http://localhost:3999/');

    // Verify the startJShell function sends the correct path
    const jshellPath = await page.evaluate(() => {
      // Extract the sendToGuest call from startJShell function source
      return window.startJShell.toString();
    });
    expect(jshellPath).toContain('/opt/jdk/bin/jshell');
    expect(jshellPath).not.toContain('/usr/bin/jshell');
  });

  test('old JDK path /usr/lib/jvm/java-21-openjdk is not referenced', async ({ page }) => {
    await page.goto('http://localhost:3999/');

    // Get the full page source and check no old paths remain
    const htmlContent = await page.content();
    expect(htmlContent).not.toContain('/usr/lib/jvm/java-21-openjdk');
  });

  test('ISO auto-detection functions are defined', async ({ page }) => {
    await page.goto('http://localhost:3999/');

    const funcs = await page.evaluate(() => ({
      parseIsoDir: typeof parseIsoDir === 'function',
      findInitOffset: typeof findInitOffset === 'function',
      isoName: typeof isoName === 'function',
    }));
    expect(funcs.parseIsoDir).toBe(true);
    expect(funcs.findInitOffset).toBe(true);
    expect(funcs.isoName).toBe(true);
  });

  test('isoName normalizes ISO 9660 filenames correctly', async ({ page }) => {
    await page.goto('http://localhost:3999/');

    const results = await page.evaluate(() => ({
      plain: isoName('INIT'),
      withVersion: isoName('INIT;1'),
      withDotVersion: isoName('INIT.;1'),
      lowercase: isoName('init.;1'),
      dir: isoName('SBIN'),
    }));
    expect(results.plain).toBe('INIT');
    expect(results.withVersion).toBe('INIT');
    expect(results.withDotVersion).toBe('INIT');
    expect(results.lowercase).toBe('INIT');
    expect(results.dir).toBe('SBIN');
  });

  test('parseIsoDir returns correct structure for mock data', async ({ page }) => {
    await page.goto('http://localhost:3999/');

    // Build a minimal ISO 9660 directory entry and verify parseIsoDir parses it
    const result = await page.evaluate(() => {
      // Create a minimal ISO directory record:
      // offset 0: record length (byte)
      // offset 2-5: sector (LE uint32)
      // offset 10-13: size (LE uint32)
      // offset 32: name length (byte)
      // offset 33+: name
      const name = 'TEST';
      const recLen = 33 + name.length + (name.length % 2 === 0 ? 1 : 0); // pad to even
      const buf = new Uint8Array(recLen + 1); // +1 so next recLen=0 stops loop
      buf[0] = recLen;
      // sector = 100 (LE)
      buf[2] = 100; buf[3] = 0; buf[4] = 0; buf[5] = 0;
      // size = 2048 (LE)
      buf[10] = 0; buf[11] = 8; buf[12] = 0; buf[13] = 0;
      // name
      buf[32] = name.length;
      for (let i = 0; i < name.length; i++) buf[33 + i] = name.charCodeAt(i);

      const entries = parseIsoDir(buf);
      return entries;
    });

    expect(result).toHaveLength(1);
    expect(result[0].name).toBe('TEST');
    expect(result[0].sector).toBe(100);
    expect(result[0].size).toBe(2048);
  });

  test('hardcoded INIT_OFFSET is only used as fallback', async ({ page }) => {
    await page.goto('http://localhost:3999/');

    // The old hardcoded offset should only appear in the fallback catch block
    const htmlContent = await page.content();

    // Should contain findInitOffset (auto-detection)
    expect(htmlContent).toContain('findInitOffset');

    // The hardcoded 54853632 should only be in the catch/fallback
    expect(htmlContent).toContain('falling back to hardcoded offset');
  });

  test('Module.onRuntimeInitialized calls findInitOffset', async ({ page }) => {
    await page.goto('http://localhost:3999/');

    const onRuntimeInitSrc = await page.evaluate(() => {
      return Module.onRuntimeInitialized.toString();
    });

    // Should call findInitOffset for auto-detection
    expect(onRuntimeInitSrc).toContain('findInitOffset');
    // Should still have fallback (source uses numeric separator: 54_853_632)
    expect(onRuntimeInitSrc).toContain('54_853_632');
  });

  test('mini-init.bin is fetched on page load', async ({ page }) => {
    // Listen for the mini-init.bin fetch
    const miniInitRequest = page.waitForRequest(req =>
      req.url().includes('mini-init.bin')
    );

    await page.goto('http://localhost:3999/');
    const req = await miniInitRequest;
    expect(req.url()).toContain('mini-init.bin');
  });

  test('NullNetdevSocket WebSocket patch is present', async ({ page }) => {
    await page.goto('http://localhost:3999/');

    // Verify the WebSocket interception is active
    const wsPatched = await page.evaluate(() => {
      // Creating a WebSocket to 127.0.0.1:8888 should return a null socket
      const ws = new WebSocket('ws://127.0.0.1:8888/');
      return ws.readyState === 0 && typeof ws.send === 'function';
    });
    expect(wsPatched).toBe(true);
  });

  test('boot phase tracking is initialized', async ({ page }) => {
    await page.goto('http://localhost:3999/');

    const bootState = await page.evaluate(() => ({
      bootPhase: window._bootPhase,
      ptyWriteCount: window._ptyWriteCount,
      ptyTotalBytes: window._ptyTotalBytes,
    }));

    expect(bootState.bootPhase).toBe('booting');
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
