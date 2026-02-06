// @ts-check
const { test, expect } = require('@playwright/test');

// Universe hash is passed via environment or auto-detected
const UNIVERSE = process.env.JTW_UNIVERSE || '';
const COMPILER = process.env.JTW_COMPILER || '5.4.0';

test.describe('OHC JTW Integration', () => {
  test.setTimeout(120000);

  test('worker initializes and executes OCaml with fmt', async ({ page }) => {
    // Collect console logs for debugging
    const logs = [];
    page.on('console', msg => logs.push(msg.text()));

    await page.goto(`/test/ohc-integration/test.html?universe=${UNIVERSE}&compiler=${COMPILER}`);

    // Wait for tests to complete (or error)
    await expect(async () => {
      const done = await page.locator('#status').getAttribute('data-done');
      const error = await page.locator('#status').getAttribute('data-error');
      expect(done === 'true' || error !== null).toBeTruthy();
    }).toPass({ timeout: 120000 });

    // Check no error occurred
    const error = await page.locator('#status').getAttribute('data-error');
    if (error) {
      console.log('Console logs:', logs.join('\n'));
    }
    expect(error).toBeNull();

    // Verify individual test results
    const results = page.locator('#results');

    // Test 1: Basic arithmetic
    const test1 = await results.getAttribute('data-test1');
    expect(test1).toContain('val x : int = 3');

    // Test 2: String operations
    const test2 = await results.getAttribute('data-test2');
    expect(test2).toContain('"hello, world"');

    // Test 3: fmt loaded
    const test3 = await results.getAttribute('data-test3');
    expect(test3).toBe('loaded');

    // Test 4: Fmt.str works
    const test4 = await results.getAttribute('data-test4');
    expect(test4).toContain('"42"');

    // Test 5: Completions work
    const test5 = await results.getAttribute('data-test5');
    expect(test5).toBe('ok');
  });
});
