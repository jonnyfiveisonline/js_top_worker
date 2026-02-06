// @ts-check
const { test, expect } = require('@playwright/test');

const BASE = 'http://localhost:8769/test/ohc-integration/tutorials';

// Generous timeout for worker init + package loading + step execution
test.describe.configure({ timeout: 180_000 });

/**
 * Helper: load a tutorial page, wait for all steps to finish,
 * return { passed, failed, total, failures[] }.
 */
async function runTutorial(page, pkg) {
  await page.goto(`${BASE}/tutorial.html?pkg=${encodeURIComponent(pkg)}`);

  // Wait for init status to disappear (worker loaded, packages loaded)
  await page.waitForSelector('#init-status', { state: 'hidden', timeout: 120_000 });

  // Wait for all steps to finish: progress bar gets class 'done'
  await page.waitForSelector('.progress-bar.done', { timeout: 120_000 });

  // Gather results
  const results = await page.evaluate(() => {
    const steps = document.querySelectorAll('.step');
    const failures = [];
    let passed = 0, failed = 0;
    for (const step of steps) {
      if (step.classList.contains('pass')) {
        passed++;
      } else if (step.classList.contains('fail')) {
        failed++;
        const code = step.querySelector('.step-code code')?.textContent || '';
        const output = step.querySelector('.step-output')?.textContent || '';
        const error = step.querySelector('.step-error')?.textContent || '';
        failures.push({ code, output, error });
      }
    }
    return { passed, failed, total: steps.length, failures };
  });

  return results;
}

// ── Test a representative sample across all library types ──────────────

test('fmt.0.11.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'fmt.0.11.0');
  if (r.failures.length > 0) {
    console.log('Failures:', JSON.stringify(r.failures, null, 2));
  }
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
  expect(r.passed).toBe(r.total);
});

test('cmdliner.1.0.4 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'cmdliner.1.0.4');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('cmdliner.2.1.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'cmdliner.2.1.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('mtime.1.3.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'mtime.1.3.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('mtime.2.1.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'mtime.2.1.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('astring.0.8.5 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'astring.0.8.5');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('jsonm.1.0.2 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'jsonm.1.0.2');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('ptime.1.2.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'ptime.1.2.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('hmap.0.8.1 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'hmap.0.8.1');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('react.1.2.2 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'react.1.2.2');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('gg.1.0.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'gg.1.0.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('fpath.0.7.3 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'fpath.0.7.3');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('uutf.1.0.4 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'uutf.1.0.4');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('bos.0.2.1 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'bos.0.2.1');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('uucp.14.0.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'uucp.14.0.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('note.0.0.3 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'note.0.0.3');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('vg.0.9.5 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'vg.0.9.5');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('b0.0.0.6 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'b0.0.0.6');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('logs.0.10.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'logs.0.10.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('xmlm.1.4.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'xmlm.1.4.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

// ── Remaining versions ────────────────────────────────────────────────

test('fmt.0.9.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'fmt.0.9.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('fmt.0.10.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'fmt.0.10.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('cmdliner.1.3.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'cmdliner.1.3.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('cmdliner.2.0.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'cmdliner.2.0.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('mtime.1.4.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'mtime.1.4.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test.skip('logs.0.7.0 tutorial — broken universe (inconsistent assumptions)', async ({ page }) => {
  const r = await runTutorial(page, 'logs.0.7.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('uucp.15.0.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'uucp.15.0.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('uucp.16.0.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'uucp.16.0.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('uucp.17.0.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'uucp.17.0.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('uunf.14.0.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'uunf.14.0.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('uunf.17.0.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'uunf.17.0.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

test('otfm.0.4.0 tutorial', async ({ page }) => {
  const r = await runTutorial(page, 'otfm.0.4.0');
  if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
  expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
});

// ── New library tutorials (added packages) ────────────────────────────

const newTutorials = [
  'yojson.3.0.0',
  'ezjsonm.1.1.0', 'ezjsonm.1.2.0', 'ezjsonm.1.3.0',
  'sexplib0.v0.17.0',
  'base64.3.5.2',
  're.1.10.4', 're.1.11.0', 're.1.12.0', 're.1.13.2', 're.1.14.0',
  'angstrom.0.16.1',
  'tyre.0.5', 'tyre.1.0',
  'uuseg.14.0.0', 'uuseg.15.0.0', 'uuseg.16.0.0', 'uuseg.17.0.0',
  'containers.3.17',
  'iter.1.7', 'iter.1.8', 'iter.1.9',
  'ocamlgraph.2.0.0', 'ocamlgraph.2.1.0', 'ocamlgraph.2.2.0',
  'hex.1.4.0', 'hex.1.5.0',
  'eqaf.0.9', 'eqaf.0.10',
  'uri.4.4.0',
  'ipaddr.5.6.0', 'ipaddr.5.6.1',
  'domain-name.0.4.1', 'domain-name.0.5.0',
  'qcheck-core.0.25', 'qcheck-core.0.27', 'qcheck-core.0.91',
];

// These packages have broken jtw layers (inconsistent .cmi assumptions,
// wrong OCaml version, undefined compilation units, or missing JS stubs)
const skippedTutorials = [
  'yojson.1.7.0', 'yojson.2.0.2', 'yojson.2.1.2', 'yojson.2.2.2',
  'angstrom.0.15.0',
  'base64.3.4.0',
  'sexplib0.v0.15.1', 'sexplib0.v0.16.0',
  'csexp.1.5.2',
  'containers.3.12', 'containers.3.14',
  'digestif.1.1.2', 'digestif.1.3.0',
  'uri.4.2.0',
  'zarith.1.13', 'zarith.1.14',
];

for (const pkg of skippedTutorials) {
  test.skip(`${pkg} tutorial — needs combined universe`, () => {});
}

for (const pkg of newTutorials) {
  test(`${pkg} tutorial`, async ({ page }) => {
    const r = await runTutorial(page, pkg);
    if (r.failures.length > 0) console.log('Failures:', JSON.stringify(r.failures, null, 2));
    expect(r.failed, `${r.failed} failures: ${JSON.stringify(r.failures)}`).toBe(0);
  });
}
