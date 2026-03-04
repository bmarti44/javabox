// @ts-check
const { defineConfig } = require('@playwright/test');
const path = require('path');

module.exports = defineConfig({
  testDir: './tests',
  timeout: 30000,
  use: {
    browserName: 'chromium',
  },
  webServer: {
    command: `python3 ${path.join(__dirname, 'build/serve.py')} ${path.join(__dirname, 'build/www')} 3999`,
    port: 3999,
    reuseExistingServer: true,
    timeout: 10000,
  },
});
