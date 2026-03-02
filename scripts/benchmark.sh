#!/usr/bin/env bash
# scripts/benchmark.sh — Measure JavaBox compile/run timing
#
# Runs a series of Java programs inside a live container and reports timing.
# Requires the container to be running (boot it first via the browser or SDK).
#
# Usage: ./scripts/benchmark.sh <wasm-htdocs-dir>
#
# The benchmark uses puppeteer (headless Chrome) to boot the container and
# run timing measurements programmatically.
#
# Prerequisites:
#   npm install -g puppeteer

set -euo pipefail

HTDOCS="${1:-/tmp/javabox-out/htdocs}"
REPORT="./benchmark-$(date +%Y%m%d-%H%M%S).txt"

echo "==> JavaBox Benchmark"
echo "    htdocs: ${HTDOCS}"
echo "    report: ${REPORT}"
echo ""

# Check puppeteer is available
if ! command -v node &>/dev/null; then
  echo "ERROR: node not found. Install Node.js to run browser benchmarks."
  exit 1
fi

# Check the htdocs has the necessary files
for f in out.js out.wasm out.data; do
  if [ ! -f "${HTDOCS}/${f}" ]; then
    echo "ERROR: ${HTDOCS}/${f} not found. Run ./build/convert.sh first."
    exit 1
  fi
done

# ── Benchmark script (inline Node.js) ─────────────────────────────────────────
node - "${HTDOCS}" "${REPORT}" <<'NODEEOF'
const puppeteer = require('puppeteer');
const http = require('http');
const fs = require('fs');
const path = require('path');

const htdocs = process.argv[2];
const reportFile = process.argv[3];

// Simple static file server with COOP/COEP headers
function createServer(dir) {
  return http.createServer((req, res) => {
    const filePath = path.join(dir, req.url === '/' ? '/index.html' : req.url);
    try {
      const data = fs.readFileSync(filePath);
      const ext = path.extname(filePath);
      const contentType = {
        '.js': 'application/javascript',
        '.wasm': 'application/wasm',
        '.html': 'text/html',
      }[ext] || 'application/octet-stream';

      res.writeHead(200, {
        'Content-Type': contentType,
        'Cross-Origin-Opener-Policy': 'same-origin',
        'Cross-Origin-Embedder-Policy': 'require-corp',
      });
      res.end(data);
    } catch {
      res.writeHead(404);
      res.end('Not found');
    }
  });
}

async function runBenchmark() {
  const server = createServer(htdocs);
  await new Promise(r => server.listen(0, r));
  const port = server.address().port;
  const baseUrl = `http://localhost:${port}`;

  const browser = await puppeteer.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
  });

  const results = {
    timestamp: new Date().toISOString(),
    wasmDir: htdocs,
    metrics: {},
  };

  try {
    const page = await browser.newPage();

    // Capture console output for timing markers
    const timings = {};
    page.on('console', msg => {
      const text = msg.text();
      if (text.startsWith('BENCH:')) {
        const [, key, value] = text.split(':');
        timings[key.trim()] = parseFloat(value);
      }
    });

    // Instrument page for timing
    await page.goto(`${baseUrl}/`);

    // Wait for boot (up to 3 minutes)
    console.log('Waiting for container boot...');
    const bootStart = Date.now();
    await page.waitForFunction(() => window.__javboxReady === true, { timeout: 180000 });
    results.metrics.bootTimeMs = Date.now() - bootStart;
    console.log(`Boot time: ${results.metrics.bootTimeMs}ms`);

    // HelloWorld benchmark
    const helloResult = await page.evaluate(() => {
      return window.__javaboxBenchmark('Hello World');
    });
    results.metrics.helloWorldCompileMs = helloResult.compileMs;
    results.metrics.helloWorldRunMs = helloResult.runMs;

    // Memory usage
    const memInfo = await page.evaluate(() => {
      return performance.memory ? {
        usedJSHeapSizeMB: Math.round(performance.memory.usedJSHeapSize / 1024 / 1024),
        totalJSHeapSizeMB: Math.round(performance.memory.totalJSHeapSize / 1024 / 1024),
      } : null;
    });
    if (memInfo) results.metrics.memory = memInfo;

  } finally {
    await browser.close();
    server.close();
  }

  // Write report
  const report = [
    '=== JavaBox Benchmark Report ===',
    `Date: ${results.timestamp}`,
    `WASM dir: ${results.wasmDir}`,
    '',
    '--- Timing ---',
    `Boot time:           ${results.metrics.bootTimeMs}ms`,
    `HelloWorld compile:  ${results.metrics.helloWorldCompileMs}ms`,
    `HelloWorld run:      ${results.metrics.helloWorldRunMs}ms`,
    '',
    '--- Memory ---',
    results.metrics.memory
      ? `JS heap used:  ${results.metrics.memory.usedJSHeapSizeMB}MB`
      : 'Memory info not available',
  ].join('\n');

  console.log('\n' + report);
  fs.writeFileSync(reportFile, report);
  console.log(`\nReport saved to: ${reportFile}`);
}

runBenchmark().catch(err => {
  console.error('Benchmark failed:', err);
  process.exit(1);
});
NODEEOF

echo ""
echo "==> Benchmark complete. Report: ${REPORT}"
