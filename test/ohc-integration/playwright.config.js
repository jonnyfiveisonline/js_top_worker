// @ts-check
const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: '.',
  timeout: 120000,
  retries: 0,
  use: {
    baseURL: 'http://localhost:8769',
  },
  webServer: {
    command: 'python3 -m http.server 8769',
    cwd: process.env.JTW_SERVE_DIR || '/home/jons-agent/js_top_worker',
    port: 8769,
    timeout: 10000,
    reuseExistingServer: true,
  },
  reporter: 'list',
});
