const { chromium } = require('playwright');

async function testFeatures() {
  console.log('Launching browser...');
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const page = await browser.newPage();

  // Collect all console messages
  const consoleMessages = [];
  page.on('console', msg => {
    consoleMessages.push(msg.text());
    console.log('[browser] ' + msg.text());
  });
  page.on('pageerror', err => console.log('[page error] ' + err.message));

  console.log('Navigating to demo page...');
  await page.goto('http://localhost:8091/demo.html');

  // Wait for ready
  console.log('Waiting for worker to initialize...');
  try {
    await page.waitForFunction(
      () => document.getElementById('status-text')?.textContent === 'Ready',
      { timeout: 60000 }
    );
    console.log('Worker ready!\n');
  } catch (e) {
    console.log('Worker init failed');
    await browser.close();
    return;
  }

  // Test 1: MIME Output
  console.log('=== TEST 1: MIME Output ===');
  const mimeCode = `let svg = {|<svg width="100" height="100"><circle cx="50" cy="50" r="40" fill="blue"/></svg>|};;
Mime_printer.push "image/svg+xml" svg;;`;
  await page.fill('#mime-input', mimeCode);
  await page.evaluate(() => runMime());
  await page.waitForTimeout(5000);
  const mimeOutput = await page.evaluate(() => document.getElementById('mime-output')?.textContent);
  const mimeRendered = await page.evaluate(() => document.getElementById('mime-rendered')?.innerHTML);
  console.log('MIME Output:', mimeOutput?.substring(0, 200));
  console.log('MIME Rendered:', mimeRendered?.substring(0, 200) || '(empty)');
  console.log('');

  // Test 2: Autocomplete
  console.log('=== TEST 2: Autocomplete ===');
  await page.fill('#complete-input', 'List.m');
  await page.evaluate(() => runComplete());
  await page.waitForTimeout(3000);
  const completeOutput = await page.evaluate(() => document.getElementById('complete-output')?.textContent);
  console.log('Complete Output:', completeOutput?.substring(0, 300));
  console.log('');

  // Test 3: Type Information
  console.log('=== TEST 3: Type Information ===');
  await page.fill('#type-input', 'let x = List.map');
  await page.fill('#type-pos', '10');
  await page.evaluate(() => runTypeEnclosing());
  await page.waitForTimeout(3000);
  const typeOutput = await page.evaluate(() => document.getElementById('type-output')?.textContent);
  console.log('Type Output:', typeOutput?.substring(0, 300));
  console.log('');

  // Test 4: Error Reporting
  console.log('=== TEST 4: Error Reporting ===');
  await page.fill('#errors-input', 'let x : string = 42');
  await page.evaluate(() => runQueryErrors());
  await page.waitForTimeout(3000);
  const errorsOutput = await page.evaluate(() => document.getElementById('errors-output')?.textContent);
  console.log('Errors Output:', errorsOutput?.substring(0, 300));
  console.log('');

  // Test 5: Custom Printers
  console.log('=== TEST 5: Custom Printers ===');
  const printerCode = `type point = { x: int; y: int };;
let p = { x = 10; y = 20 };;`;
  await page.fill('#printer-input', printerCode);
  await page.evaluate(() => runPrinter());
  await page.waitForTimeout(3000);
  const printerOutput = await page.evaluate(() => document.getElementById('printer-output')?.textContent);
  console.log('Printer Output:', printerOutput?.substring(0, 300));
  console.log('');

  // Test 6: Library Loading
  console.log('=== TEST 6: Library Loading ===');
  const requireCode = `#require "str";;
Str.string_match (Str.regexp "hello") "hello world" 0;;`;
  await page.fill('#require-input', requireCode);
  await page.evaluate(() => runRequire());
  await page.waitForTimeout(5000);
  const requireOutput = await page.evaluate(() => document.getElementById('require-output')?.textContent);
  console.log('Require Output:', requireOutput?.substring(0, 300));
  console.log('');

  // Print any errors from console
  const errors = consoleMessages.filter(m => m.includes('Error') || m.includes('error') || m.includes('Exception'));
  if (errors.length > 0) {
    console.log('=== ERRORS FOUND ===');
    errors.forEach(e => console.log(e));
  }

  await browser.close();
}

testFeatures().catch(console.error);
