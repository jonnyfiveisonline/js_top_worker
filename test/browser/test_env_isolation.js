/**
 * Test environment isolation in js_top_worker
 */

const { chromium } = require('playwright');

async function testEnvIsolation() {
  console.log('Launching browser...');
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const page = await browser.newPage();
  page.on('console', msg => console.log(`[browser ${msg.type()}] ${msg.text()}`));

  console.log('Navigating to demo page...');
  await page.goto('http://localhost:8000/demo.html', { timeout: 30000 });

  // Wait for initialization
  console.log('Waiting for toplevel to initialize...');
  await page.waitForFunction(
    () => document.getElementById('status-indicator')?.classList.contains('ready'),
    { timeout: 60000 }
  );
  console.log('✓ Toplevel initialized');

  // Test environment isolation
  console.log('\n=== Testing Environment Isolation ===\n');

  // Step 1: Set env_value = 100 in default environment
  console.log('Step 1: Setting env_value = 100 in default environment...');
  await page.fill('#env-input', 'let env_value = 100;;');
  await page.click('button:has-text("Execute in Selected Env")');
  await page.waitForTimeout(2000);

  let output = await page.$eval('#env-output', el => el.textContent);
  console.log(`  Output: ${output}`);

  // Step 2: Create a new environment
  console.log('\nStep 2: Creating env1...');
  await page.click('button:has-text("+ New Env")');
  await page.waitForTimeout(2000);

  // Step 3: Set env_value = 200 in env1
  console.log('Step 3: Setting env_value = 200 in env1...');
  await page.fill('#env-input', 'let env_value = 200;;');
  await page.click('button:has-text("Execute in Selected Env")');
  await page.waitForTimeout(2000);

  output = await page.$eval('#env-output', el => el.textContent);
  console.log(`  Output: ${output}`);

  // Step 4: Check env_value in env1 (should be 200)
  console.log('\nStep 4: Checking env_value in env1 (should be 200)...');
  await page.fill('#env-input', 'env_value;;');
  await page.click('button:has-text("Execute in Selected Env")');
  await page.waitForTimeout(2000);

  output = await page.$eval('#env-output', el => el.textContent);
  console.log(`  Output: ${output}`);
  const env1Value = output.includes('200') ? 200 : (output.includes('100') ? 100 : 'unknown');
  console.log(`  env_value in env1 = ${env1Value}`);

  // Step 5: Switch back to default environment
  console.log('\nStep 5: Switching to default environment...');
  await page.click('.env-btn[data-env=""]');
  await page.waitForTimeout(500);

  // Step 6: Check env_value in default (should be 100)
  console.log('Step 6: Checking env_value in default (should be 100)...');
  await page.fill('#env-input', 'env_value;;');
  await page.click('button:has-text("Execute in Selected Env")');
  await page.waitForTimeout(2000);

  output = await page.$eval('#env-output', el => el.textContent);
  console.log(`  Output: ${output}`);
  const defaultValue = output.includes('100') ? 100 : (output.includes('200') ? 200 : 'unknown');
  console.log(`  env_value in default = ${defaultValue}`);

  // Summary
  console.log('\n=== RESULTS ===');
  console.log(`env1 value: ${env1Value} (expected: 200)`);
  console.log(`default value: ${defaultValue} (expected: 100)`);

  if (env1Value === 200 && defaultValue === 100) {
    console.log('\n✓ Environment isolation WORKS correctly');
  } else {
    console.log('\n✗ Environment isolation BROKEN');
    console.log('  Both environments share the same state!');
  }

  await browser.close();
}

testEnvIsolation().catch(e => {
  console.error('Test error:', e);
  process.exit(1);
});
