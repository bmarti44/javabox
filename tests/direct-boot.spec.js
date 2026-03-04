// @ts-check
const { test, expect } = require('@playwright/test');

test('direct WASM: boot and compile HelloWorld', async ({ page }) => {
  test.setTimeout(120000);

  page.on('console', msg => console.log(`[B:${msg.type()}]`, msg.text()));
  page.on('pageerror', err => console.log('[PAGE ERROR]', err.message));

  await page.goto('http://localhost:3999/index.html?mode=direct', { waitUntil: 'domcontentloaded' });

  // 1. Wait for JVM boot (JBOX_PONG from auto-ping in index.html)
  let booted = false;
  for (let i = 0; i < 16; i++) {
    await page.waitForTimeout(5000);
    const text = await page.evaluate(() => window._ptyRecentText || '');
    const status = await page.evaluate(() => document.getElementById('status')?.textContent || '');
    console.log(`[BOOT ${(i+1)*5}s] status="${status}", has PONG: ${text.includes('JBOX_PONG')}`);
    if (text.includes('JBOX_PONG')) {
      booted = true;
      console.log(`[TEST] Booted in ${(i+1)*5}s`);
      break;
    }
  }
  expect(booted).toBe(true);

  // 2. Clear tracked output, then send JBOX_COMPILE HelloWorld
  console.log('[TEST] Sending JBOX_COMPILE HelloWorld...');
  await page.evaluate(() => {
    window._ptyRecentText = '';
    const code = [
      'JBOX_COMPILE HelloWorld',
      'public class HelloWorld {',
      '    public static void main(String[] args) {',
      '        System.out.println("Hello from WASM JVM!");',
      '    }',
      '}',
      'JBOX_END',
    ].join('\n') + '\n';
    window.sendToGuest(code);
  });

  // 3. Wait for compilation result
  let compileOutput = '';
  let foundExit = false;
  for (let i = 0; i < 12; i++) {
    await page.waitForTimeout(5000);
    compileOutput = await page.evaluate(() => window._ptyRecentText || '');
    console.log(`[COMPILE ${(i+1)*5}s] output length=${compileOutput.length}, last 200: ${JSON.stringify(compileOutput.slice(-200))}`);
    if (compileOutput.includes('JBOX_EXIT:')) {
      foundExit = true;
      break;
    }
  }

  console.log('[FINAL OUTPUT]', JSON.stringify(compileOutput));
  expect(compileOutput).toContain('Hello from WASM JVM!');
  expect(compileOutput).toContain('JBOX_EXIT:0');
});
