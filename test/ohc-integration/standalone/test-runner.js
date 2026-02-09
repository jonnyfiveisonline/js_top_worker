import { OcamlWorker } from '/client/ocaml-worker.js';

/**
 * Run a set of tests for a blessed package in the browser.
 *
 * @param {object} config
 * @param {string} config.pkg        - Blessed package spec, e.g. 'fmt.0.9.0'
 * @param {string} [config.universe] - Universe hash (preferred over blessed path)
 * @param {string} config.compiler   - Compiler version, e.g. '5.4.0'
 * @param {string} config.title      - Display title
 * @param {string} config.subtitle   - Subtitle text (compiler + variant info)
 * @param {string} [config.tag]      - Optional tag text
 * @param {string} [config.tagClass] - CSS class for the tag
 * @param {string} config.description - Short description paragraph
 * @param {string} config.require    - Findlib package name to #require
 * @param {Array}  config.tests      - Array of test objects
 *
 * Each test object:
 *   name:        string  - display name
 *   code:        string  - OCaml code to eval
 *   contains:    string  - (optional) expected substring; PASS if found
 *   notContains: string  - (optional) unexpected substring; PASS if absent
 *   field:       string  - 'caml_ppf' (default), 'stdout', 'stderr', or 'combined'
 */
export async function runTests(config) {
  // Build the page DOM
  document.body.innerHTML = '';

  const backLink = el('a', { className: 'back', href: 'index.html' }, '\u2190 All tests');
  document.body.appendChild(backLink);

  const h1 = el('h1', {}, config.title + ' ');
  const sub = el('span', { className: 'subtitle' }, config.subtitle);
  h1.appendChild(sub);
  if (config.tag) {
    const tag = el('span', { className: 'tag ' + (config.tagClass || '') }, config.tag);
    h1.appendChild(tag);
  }
  document.body.appendChild(h1);

  const desc = el('p', { className: 'description' }, config.description);
  document.body.appendChild(desc);

  const statusEl = el('div', { id: 'status', className: 'status-loading' }, 'Initializing worker\u2026');
  document.body.appendChild(statusEl);

  const testsEl = el('div', { id: 'tests' });
  document.body.appendChild(testsEl);

  function addTest(name) {
    const div = el('div', { className: 'test test-pending' });
    div.innerHTML = `<h3>${esc(name)}</h3><pre class="output">running\u2026</pre><div class="result"></div>`;
    testsEl.appendChild(div);
    return div;
  }

  function markPass(div, output) {
    div.className = 'test test-pass';
    div.querySelector('.output').textContent = output;
    div.querySelector('.result').innerHTML = '<span class="pass">PASS</span>';
  }

  function markFail(div, output, reason) {
    div.className = 'test test-fail';
    div.querySelector('.output').textContent = output;
    div.querySelector('.result').innerHTML = `<span class="fail">FAIL: ${esc(reason)}</span>`;
  }

  try {
    // Resolve findlib_index URL: prefer universe path, fall back to blessed
    let indexUrl;
    if (config.universe) {
      indexUrl = `/jtw-output/u/${config.universe}/findlib_index`;
    } else {
      const [name, ver] = [
        config.pkg.substring(0, config.pkg.indexOf('.')),
        config.pkg.substring(config.pkg.indexOf('.') + 1),
      ];
      indexUrl = `/jtw-output/p/${name}/${ver}/findlib_index`;
    }
    const { worker, stdlib_dcs, findlib_index } = await OcamlWorker.fromIndex(
      indexUrl, '/jtw-output', { timeout: 120000 });

    statusEl.textContent = 'Loading stdlib\u2026';
    await worker.init({ findlib_requires: [], stdlib_dcs, findlib_index });

    statusEl.textContent = `Loading ${config.require}\u2026`;
    const rReq = await worker.eval(`#require "${config.require}";;`);
    if (rReq.stderr && rReq.stderr.includes('Cannot load')) {
      throw new Error(`#require "${config.require}" failed: ${rReq.stderr}`);
    }

    statusEl.textContent = 'Running tests\u2026';
    statusEl.className = 'status-ready';

    let allPassed = true;
    for (const t of config.tests) {
      const div = addTest(t.name);
      const r = await worker.eval(t.code);
      const out = `> ${t.code}\n${formatResult(r)}`;

      const field = t.field || 'caml_ppf';
      const value = field === 'combined'
        ? (r.caml_ppf || '') + (r.stderr || '')
        : field === 'stdout' ? (r.stdout || '')
        : field === 'stderr' ? (r.stderr || '')
        : (r.caml_ppf || '');

      if (t.contains != null) {
        if (value.includes(t.contains)) {
          markPass(div, out);
        } else {
          markFail(div, out, `expected "${t.contains}" in ${field}`);
          allPassed = false;
        }
      } else if (t.notContains != null) {
        if (!value.includes(t.notContains)) {
          markPass(div, out);
        } else {
          markFail(div, out, `unexpected "${t.notContains}" in ${field}`);
          allPassed = false;
        }
      }
    }

    statusEl.textContent = allPassed ? 'All tests passed' : 'Some tests failed';
    if (!allPassed) statusEl.className = 'status-error';

  } catch (err) {
    statusEl.textContent = 'Error: ' + err.message;
    statusEl.className = 'status-error';
  }
}

function formatResult(r) {
  let s = '';
  if (r.caml_ppf) s += r.caml_ppf;
  if (r.stdout) s += (s ? '\n' : '') + '[stdout] ' + r.stdout;
  if (r.stderr) s += (s ? '\n' : '') + '[stderr] ' + r.stderr;
  return s || '(no output)';
}

function el(tag, attrs, text) {
  const e = document.createElement(tag);
  if (attrs) Object.assign(e, attrs);
  if (text) e.textContent = text;
  return e;
}

function esc(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
