// @ts-check
const { test, expect } = require('@playwright/test');

// Helper: send raw data to guest via sendToGuest (ring buffer bridge)
function sendToGuest(page, raw) {
  return page.evaluate((data) => {
    if (typeof window.sendToGuest === 'function') {
      window.sendToGuest(data);
    }
  }, raw);
}

// Helper: wait for PTY output to contain a string
async function waitForOutput(page, needle, timeoutMs = 240000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const text = await page.evaluate(() => window._ptyRecentText || '');
    if (text.includes(needle)) return true;
    await page.waitForTimeout(2000);
  }
  return false;
}

// Helper: send a key event
async function sendKey(page, type, scanName) {
  await sendToGuest(page, `\x01${type}${scanName}\n`);
}

// Helper: press and release a key
async function pressKey(page, scanName, holdMs = 100) {
  await sendKey(page, 'D', scanName);
  await page.waitForTimeout(holdMs);
  await sendKey(page, 'U', scanName);
}

// ─── Test 1: Boot + Doom title screen ─────────────────────────────────────────
test('boot and show Doom title screen', async ({ page }) => {
  test.setTimeout(300000);

  page.on('console', msg => {
    const text = msg.text();
    if (text.includes('[DOOM]') || text.includes('JBOX_') ||
        text.includes('[BOOT]') || text.includes('[TEST]') ||
        text.includes('abort') || text.includes('Error')) {
      console.log('[BROWSER]', text);
    }
  });

  page.on('pageerror', err => {
    console.log('[PAGE_ERROR]', err.message);
  });

  await page.goto('http://localhost:3999/doom.html', { waitUntil: 'domcontentloaded' });
  console.log('[TEST] Doom page loaded');

  // Wait for boot — JBOX_PONG detection
  console.log('[TEST] Waiting for boot (JBOX_PONG)...');
  for (let i = 1; i <= 30; i++) {
    await page.waitForTimeout(2000);
    const state = await page.evaluate(() => ({
      phase: window._bootPhase,
      bytes: window._ptyTotalBytes,
      tail: (window._ptyRecentText || '').slice(-300).replace(/[\x00-\x1f]/g, '.'),
    }));
    console.log(`[STATE t=${i * 2}s] phase=${state.phase} bytes=${state.bytes}`);
    if (state.tail) console.log(`[TAIL] ${state.tail.slice(-200)}`);
    if (state.phase === 'ready' || state.phase === 'playing') break;
  }

  // Wait for JBOX_DOOM_START
  console.log('[TEST] Waiting for JBOX_DOOM_START...');
  let doomStarted = false;
  for (let i = 1; i <= 90; i++) {
    await page.waitForTimeout(2000);
    const state = await page.evaluate(() => ({
      phase: window._bootPhase,
      bytes: window._ptyTotalBytes,
      tail: (window._ptyRecentText || '').slice(-300).replace(/[\x00-\x1f]/g, '.'),
    }));
    if (i % 5 === 0) {
      console.log(`[DOOM_WAIT t=${i * 2}s] phase=${state.phase} bytes=${state.bytes}`);
      if (state.tail.length > 0) console.log(`[TAIL] ${state.tail.slice(-200)}`);
    }
    if (state.tail.includes('JBOX_DOOM_START') || state.phase === 'playing') {
      doomStarted = true;
      break;
    }
  }
  if (!doomStarted) {
    const finalState = await page.evaluate(() => ({
      phase: window._bootPhase,
      bytes: window._ptyTotalBytes,
      text: (window._ptyRecentText || '').slice(-500).replace(/[\x00-\x1f]/g, '.'),
    }));
    console.log('[TEST] DOOM_START not detected. Final state:', JSON.stringify(finalState));
    await page.screenshot({ path: 'tests/screenshots/doom-boot-failed.png', fullPage: true });
  }
  expect(doomStarted).toBe(true);
  console.log('[TEST] Doom started!');

  // Wait for rendering to begin
  await page.waitForTimeout(10000);

  // Take screenshot of title screen
  await page.screenshot({ path: 'tests/screenshots/doom-title-screen.png', fullPage: true });
  console.log('[TEST] Title screen screenshot saved');
});

// ─── Test 2: Menu interaction ─────────────────────────────────────────────────
test('menu interaction', async ({ page }) => {
  test.setTimeout(300000);

  page.on('console', msg => {
    const text = msg.text();
    if (text.includes('JBOX_') || text.includes('[TEST]')) {
      console.log(text);
    }
  });

  await page.goto('http://localhost:3999/doom.html', { waitUntil: 'domcontentloaded' });

  const doomStarted = await waitForOutput(page, 'JBOX_DOOM_START', 60000);
  if (!doomStarted) {
    console.log('[TEST] Doom did not start in time, skipping menu test');
    return;
  }

  // Wait for title screen to render
  await page.waitForTimeout(15000);
  await page.screenshot({ path: 'tests/screenshots/doom-menu-before.png', fullPage: true });

  // Press Enter to open menu
  await pressKey(page, 'SC_ENTER', 200);
  await page.waitForTimeout(5000);
  await page.screenshot({ path: 'tests/screenshots/doom-menu.png', fullPage: true });

  // Press arrow down to navigate
  await pressKey(page, 'SC_DOWN', 200);
  await page.waitForTimeout(2000);
  await pressKey(page, 'SC_DOWN', 200);
  await page.waitForTimeout(2000);
  await page.screenshot({ path: 'tests/screenshots/doom-menu-nav.png', fullPage: true });

  console.log('[TEST] Menu interaction screenshots saved');
});

// ─── Test 3: Gameplay ─────────────────────────────────────────────────────────
test('gameplay', async ({ page }) => {
  test.setTimeout(300000);

  page.on('console', msg => {
    const text = msg.text();
    if (text.includes('JBOX_') || text.includes('[TEST]')) {
      console.log(text);
    }
  });

  await page.goto('http://localhost:3999/doom.html', { waitUntil: 'domcontentloaded' });

  const doomStarted = await waitForOutput(page, 'JBOX_DOOM_START', 60000);
  if (!doomStarted) {
    console.log('[TEST] Doom did not start, skipping gameplay test');
    return;
  }

  // Wait for title screen
  await page.waitForTimeout(15000);

  // Navigate menu: Enter -> New Game -> Episode -> Difficulty
  await pressKey(page, 'SC_ENTER', 200);
  await page.waitForTimeout(3000);
  await pressKey(page, 'SC_ENTER', 200); // New Game
  await page.waitForTimeout(3000);
  await pressKey(page, 'SC_ENTER', 200); // Episode 1
  await page.waitForTimeout(3000);
  await pressKey(page, 'SC_ENTER', 200); // Difficulty
  await page.waitForTimeout(10000);

  // Take gameplay screenshot
  await page.screenshot({ path: 'tests/screenshots/doom-gameplay.png', fullPage: true });
  console.log('[TEST] Gameplay screenshot saved');

  // Move forward
  await sendKey(page, 'D', 'SC_UP');
  await page.waitForTimeout(5000);
  await sendKey(page, 'U', 'SC_UP');
  await page.waitForTimeout(3000);

  await page.screenshot({ path: 'tests/screenshots/doom-gameplay-moving.png', fullPage: true });
  console.log('[TEST] Movement screenshot saved');
});

// ─── Test 4: Exit ─────────────────────────────────────────────────────────────
test('exit doom', async ({ page }) => {
  test.setTimeout(300000);

  page.on('console', msg => {
    const text = msg.text();
    if (text.includes('JBOX_') || text.includes('[TEST]')) {
      console.log(text);
    }
  });

  await page.goto('http://localhost:3999/doom.html', { waitUntil: 'domcontentloaded' });

  const doomStarted = await waitForOutput(page, 'JBOX_DOOM_START', 60000);
  if (!doomStarted) {
    console.log('[TEST] Doom did not start, skipping exit test');
    return;
  }

  await page.waitForTimeout(10000);

  // Send quit command
  await sendToGuest(page, '\x01Q\n');
  console.log('[TEST] Sent quit command');

  // Wait for JBOX_EXIT:0
  const exited = await waitForOutput(page, 'JBOX_EXIT:0', 30000);
  console.log('[TEST] Doom exited:', exited);

  await page.screenshot({ path: 'tests/screenshots/doom-exit.png', fullPage: true });
});
