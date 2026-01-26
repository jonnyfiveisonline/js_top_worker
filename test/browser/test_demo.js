/**
 * Playwright test for js_top_worker demo page
 * Run with: node test/browser/test_demo.js
 */

const { chromium } = require('playwright');

async function runTests() {
  console.log('Launching browser...');
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const context = await browser.newContext();
  const page = await context.newPage();

  // Collect console messages
  const consoleMessages = [];
  page.on('console', msg => {
    consoleMessages.push({ type: msg.type(), text: msg.text() });
    console.log(`[browser ${msg.type()}] ${msg.text()}`);
  });

  // Collect page errors
  const pageErrors = [];
  page.on('pageerror', err => {
    pageErrors.push(err.message);
    console.log(`[page error] ${err.message}`);
  });

  console.log('Navigating to demo page...');
  await page.goto('http://localhost:8000/demo.html', { timeout: 30000 });

  // Wait for initialization
  console.log('Waiting for toplevel to initialize...');
  try {
    await page.waitForFunction(
      () => document.getElementById('status-indicator')?.classList.contains('ready'),
      { timeout: 60000 }
    );
    console.log('✓ Toplevel initialized successfully');
  } catch (e) {
    const status = await page.$eval('#status-text', el => el.textContent);
    console.log(`✗ Initialization failed. Status: ${status}`);

    // Print relevant console messages
    const errors = consoleMessages.filter(m => m.type === 'error' || m.text.includes('error'));
    if (errors.length > 0) {
      console.log('Console errors:');
      errors.slice(0, 10).forEach(m => console.log(`  [${m.type}] ${m.text}`));
    }

    await browser.close();
    process.exit(1);
  }

  const results = {
    passed: [],
    failed: []
  };

  // Test 1: Basic Execution
  console.log('\nTesting Basic Execution...');
  try {
    await page.click('button:has-text("Execute"):near(#exec-input)');
    await page.waitForFunction(
      () => !document.getElementById('exec-output')?.textContent.includes('Executing...'),
      { timeout: 10000 }
    );
    const execOutput = await page.$eval('#exec-output', el => el.textContent);
    if (execOutput.includes('Hello, OCaml!')) {
      console.log('✓ Basic Execution works');
      results.passed.push('Basic Execution');
    } else {
      console.log(`✗ Basic Execution failed. Output: ${execOutput}`);
      results.failed.push({ name: 'Basic Execution', error: execOutput });
    }
  } catch (e) {
    console.log(`✗ Basic Execution error: ${e.message}`);
    results.failed.push({ name: 'Basic Execution', error: e.message });
  }

  // Test 2: Multiple Environments
  console.log('\nTesting Multiple Environments...');
  try {
    await page.click('button:has-text("+ New Env")');
    await page.waitForTimeout(1000);

    const envButtons = await page.$$eval('#env-selector .env-btn', btns => btns.map(b => b.textContent));
    if (envButtons.length > 1) {
      console.log('✓ Environment creation works');
      results.passed.push('Multiple Environments');
    } else {
      console.log(`✗ Environment creation failed. Buttons: ${envButtons.join(', ')}`);
      results.failed.push({ name: 'Multiple Environments', error: 'No new env button appeared' });
    }
  } catch (e) {
    console.log(`✗ Multiple Environments error: ${e.message}`);
    results.failed.push({ name: 'Multiple Environments', error: e.message });
  }

  // Test 3: MIME Output
  console.log('\nTesting MIME Output...');
  try {
    await page.click('button:has-text("Execute"):near(#mime-input)');
    await page.waitForFunction(
      () => !document.getElementById('mime-output')?.textContent.includes('Executing...'),
      { timeout: 10000 }
    );

    // Check if rendered MIME content is visible
    const mimeRendered = await page.$('#mime-rendered');
    const isHidden = await mimeRendered?.evaluate(el => el.classList.contains('hidden'));
    const mimeOutput = await page.$eval('#mime-output', el => el.textContent);

    if (!isHidden) {
      const svgContent = await mimeRendered?.evaluate(el => el.innerHTML);
      if (svgContent?.includes('svg') || svgContent?.includes('circle')) {
        console.log('✓ MIME Output works (SVG rendered)');
        results.passed.push('MIME Output');
      } else {
        console.log(`✗ MIME Output - SVG not rendered. Content: ${svgContent?.substring(0, 100)}`);
        results.failed.push({ name: 'MIME Output', error: 'SVG not rendered' });
      }
    } else {
      console.log(`✗ MIME Output - rendered area hidden. Output: ${mimeOutput}`);
      results.failed.push({ name: 'MIME Output', error: mimeOutput });
    }
  } catch (e) {
    console.log(`✗ MIME Output error: ${e.message}`);
    results.failed.push({ name: 'MIME Output', error: e.message });
  }

  // Test 4: Autocomplete
  console.log('\nTesting Autocomplete...');
  try {
    await page.click('button:has-text("Complete")');
    await page.waitForFunction(
      () => !document.getElementById('complete-output')?.textContent.includes('Loading...'),
      { timeout: 10000 }
    );

    const completions = await page.$eval('#complete-output', el => el.textContent);
    if (completions.includes('map') || completions.includes('mapi')) {
      console.log('✓ Autocomplete works');
      results.passed.push('Autocomplete');
    } else {
      console.log(`✗ Autocomplete failed. Output: ${completions}`);
      results.failed.push({ name: 'Autocomplete', error: completions });
    }
  } catch (e) {
    console.log(`✗ Autocomplete error: ${e.message}`);
    results.failed.push({ name: 'Autocomplete', error: e.message });
  }

  // Test 5: Type Information
  console.log('\nTesting Type Information...');
  try {
    await page.click('button:has-text("Get Type")');
    await page.waitForFunction(
      () => !document.getElementById('type-output')?.textContent.includes('Loading...'),
      { timeout: 10000 }
    );

    const typeOutput = await page.$eval('#type-output', el => el.textContent);
    if (typeOutput.includes('int') || typeOutput.includes('list') || typeOutput.includes('->')) {
      console.log('✓ Type Information works');
      results.passed.push('Type Information');
    } else {
      console.log(`✗ Type Information failed. Output: ${typeOutput}`);
      results.failed.push({ name: 'Type Information', error: typeOutput });
    }
  } catch (e) {
    console.log(`✗ Type Information error: ${e.message}`);
    results.failed.push({ name: 'Type Information', error: e.message });
  }

  // Test 6: Error Reporting
  console.log('\nTesting Error Reporting...');
  try {
    await page.click('button:has-text("Check Errors")');
    await page.waitForFunction(
      () => !document.getElementById('errors-output')?.textContent.includes('Analyzing...'),
      { timeout: 10000 }
    );

    const errorsOutput = await page.$eval('#errors-output', el => el.textContent);
    // Should find type error or unknown identifier
    if (errorsOutput.includes('Line') || errorsOutput.includes('error') || errorsOutput.includes('Error')) {
      console.log('✓ Error Reporting works');
      results.passed.push('Error Reporting');
    } else {
      console.log(`✗ Error Reporting failed. Output: ${errorsOutput}`);
      results.failed.push({ name: 'Error Reporting', error: errorsOutput });
    }
  } catch (e) {
    console.log(`✗ Error Reporting error: ${e.message}`);
    results.failed.push({ name: 'Error Reporting', error: e.message });
  }

  // Test 7: Directives - #show List
  console.log('\nTesting Directives...');
  try {
    await page.click('button:has-text("show List")');
    await page.waitForFunction(
      () => !document.getElementById('directive-output')?.textContent.includes('Executing...'),
      { timeout: 10000 }
    );

    const directiveOutput = await page.$eval('#directive-output', el => el.textContent);
    if (directiveOutput.includes('module') || directiveOutput.includes('List') || directiveOutput.includes('val')) {
      console.log('✓ Directives work');
      results.passed.push('Directives');
    } else {
      console.log(`✗ Directives failed. Output: ${directiveOutput}`);
      results.failed.push({ name: 'Directives', error: directiveOutput });
    }
  } catch (e) {
    console.log(`✗ Directives error: ${e.message}`);
    results.failed.push({ name: 'Directives', error: e.message });
  }

  // Test 8: Custom Printers
  console.log('\nTesting Custom Printers...');
  try {
    await page.click('button:has-text("Execute"):near(#printer-input)');
    await page.waitForFunction(
      () => !document.getElementById('printer-output')?.textContent.includes('Executing...'),
      { timeout: 15000 }
    );

    const printerOutput = await page.$eval('#printer-output', el => el.textContent);
    if (printerOutput.includes('[COLOR:') || printerOutput.includes('pp_color')) {
      console.log('✓ Custom Printers work');
      results.passed.push('Custom Printers');
    } else {
      console.log(`✗ Custom Printers failed. Output: ${printerOutput.substring(0, 200)}`);
      results.failed.push({ name: 'Custom Printers', error: printerOutput.substring(0, 200) });
    }
  } catch (e) {
    console.log(`✗ Custom Printers error: ${e.message}`);
    results.failed.push({ name: 'Custom Printers', error: e.message });
  }

  // Test 9: Library Loading (#require)
  console.log('\nTesting Library Loading...');
  try {
    await page.click('button:has-text("Execute"):near(#require-input)');
    await page.waitForFunction(
      () => !document.getElementById('require-output')?.textContent.includes('Executing'),
      { timeout: 30000 }
    );

    const requireOutput = await page.$eval('#require-output', el => el.textContent);
    // Str.split should return a list
    if (requireOutput.includes('["a"; "b"; "c"]') || requireOutput.includes('string list')) {
      console.log('✓ Library Loading works');
      results.passed.push('Library Loading');
    } else if (requireOutput.includes('Error') || requireOutput.includes('not found')) {
      console.log(`✗ Library Loading failed (library not available). Output: ${requireOutput}`);
      results.failed.push({ name: 'Library Loading', error: requireOutput });
    } else {
      console.log(`? Library Loading unclear. Output: ${requireOutput}`);
      results.failed.push({ name: 'Library Loading', error: requireOutput });
    }
  } catch (e) {
    console.log(`✗ Library Loading error: ${e.message}`);
    results.failed.push({ name: 'Library Loading', error: e.message });
  }

  // Test 10: Toplevel Script Execution
  console.log('\nTesting Toplevel Script Execution...');
  try {
    await page.click('button:has-text("Execute Script")');
    await page.waitForFunction(
      () => !document.getElementById('toplevel-output')?.textContent.includes('Executing script...'),
      { timeout: 15000 }
    );

    const toplevelOutput = await page.$eval('#toplevel-output', el => el.textContent);
    // Should show the squared numbers [1; 4; 9; 16; 25]
    if (toplevelOutput.includes('[1; 4; 9; 16; 25]') || toplevelOutput.includes('square')) {
      console.log('✓ Toplevel Script Execution works');
      results.passed.push('Toplevel Script Execution');
    } else {
      console.log(`✗ Toplevel Script Execution failed. Output: ${toplevelOutput.substring(0, 200)}`);
      results.failed.push({ name: 'Toplevel Script Execution', error: toplevelOutput.substring(0, 200) });
    }
  } catch (e) {
    console.log(`✗ Toplevel Script Execution error: ${e.message}`);
    results.failed.push({ name: 'Toplevel Script Execution', error: e.message });
  }

  // Summary
  console.log('\n' + '='.repeat(50));
  console.log('SUMMARY');
  console.log('='.repeat(50));
  console.log(`Passed: ${results.passed.length}`);
  console.log(`Failed: ${results.failed.length}`);

  if (results.failed.length > 0) {
    console.log('\nFailed tests:');
    results.failed.forEach(f => {
      console.log(`  - ${f.name}: ${f.error.substring(0, 100)}`);
    });
  }

  // Print any page errors
  if (pageErrors.length > 0) {
    console.log('\nPage errors encountered:');
    pageErrors.forEach(e => console.log(`  ${e}`));
  }

  await browser.close();

  process.exit(results.failed.length > 0 ? 1 : 0);
}

runTests().catch(e => {
  console.error('Test runner error:', e);
  process.exit(1);
});
