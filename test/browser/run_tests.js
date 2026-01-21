#!/usr/bin/env node
/**
 * Playwright test runner for js_top_worker_client browser tests.
 *
 * Usage:
 *   node run_tests.js [--headed]
 *
 * Starts an HTTP server, runs tests in a browser, reports results.
 */

const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 8765;
const TIMEOUT = 60000; // 60 seconds max test time

// Determine the directory where test files are located
const testDir = path.dirname(fs.realpathSync(__filename));
const buildDir = path.resolve(testDir, '../../_build/default/test/browser');

// MIME types for serving files
const mimeTypes = {
  '.html': 'text/html',
  '.js': 'application/javascript',
  '.css': 'text/css',
};

function startServer() {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      let filePath = req.url === '/' ? '/test.html' : req.url;

      // Try build directory first, then test source directory
      let fullPath = path.join(buildDir, filePath);
      if (!fs.existsSync(fullPath)) {
        fullPath = path.join(testDir, filePath);
      }

      if (!fs.existsSync(fullPath)) {
        res.writeHead(404);
        res.end('Not found: ' + filePath);
        return;
      }

      const ext = path.extname(fullPath);
      const contentType = mimeTypes[ext] || 'application/octet-stream';

      fs.readFile(fullPath, (err, content) => {
        if (err) {
          res.writeHead(500);
          res.end('Error reading file');
          return;
        }
        res.writeHead(200, { 'Content-Type': contentType });
        res.end(content);
      });
    });

    server.listen(PORT, () => {
      console.log(`Test server running at http://localhost:${PORT}/`);
      resolve(server);
    });

    server.on('error', reject);
  });
}

async function runTests(headed = false) {
  let server;
  let browser;
  let exitCode = 0;

  try {
    // Start the HTTP server
    server = await startServer();

    // Launch browser
    browser = await chromium.launch({ headless: !headed });
    const page = await browser.newPage();

    // Collect console messages
    const logs = [];
    page.on('console', msg => {
      const text = msg.text();
      logs.push(text);
      console.log(`[browser] ${text}`);
    });

    // Navigate to test page
    console.log('Loading test page...');
    await page.goto(`http://localhost:${PORT}/`);

    // Wait for tests to complete
    console.log('Waiting for tests to complete...');
    const results = await page.waitForFunction(
      () => window.testResults && window.testResults.done,
      { timeout: TIMEOUT }
    );

    // Get final results
    const testResults = await page.evaluate(() => ({
      total: window.testResults.total,
      passed: window.testResults.passed,
      failed: window.testResults.failed,
    }));

    console.log('\n========================================');
    console.log(`Test Results: ${testResults.passed}/${testResults.total} passed`);
    console.log('========================================\n');

    if (testResults.failed > 0) {
      console.log('FAILED: Some tests did not pass');
      exitCode = 1;
    } else {
      console.log('SUCCESS: All tests passed');
    }

  } catch (err) {
    console.error('Error running tests:', err.message);
    exitCode = 1;
  } finally {
    if (browser) await browser.close();
    if (server) server.close();
  }

  process.exit(exitCode);
}

// Parse command line args
const headed = process.argv.includes('--headed');
runTests(headed);
