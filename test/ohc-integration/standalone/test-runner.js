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

  // Dependency info section (populated after fetching findlib_index)
  const depsSection = el('details', { className: 'deps-section' });
  const depsSummary = el('summary', {}, 'Dependencies');
  depsSection.appendChild(depsSummary);
  document.body.appendChild(depsSection);

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
    let indexUrl, universeJsonUrl;
    if (config.universe) {
      indexUrl = `/jtw-output/u/${config.universe}/findlib_index`;
    } else {
      const [name, ver] = splitPkg(config.pkg);
      indexUrl = `/jtw-output/p/${name}/${ver}/findlib_index`;
      universeJsonUrl = `/jtw-output/p/${name}/${ver}/universe.json`;
    }

    // Fetch findlib_index (needed for worker init)
    const indexResp = await fetch(indexUrl);
    const indexData = await indexResp.json();

    // Fetch universe.json if available (for full dep versions)
    let universeData = null;
    if (universeJsonUrl) {
      try {
        const uResp = await fetch(universeJsonUrl);
        if (uResp.ok) universeData = await uResp.json();
      } catch (_) { /* ignore */ }
    }

    // Build dependency info from metas paths and universe.json
    renderDeps(depsSection, indexData, universeData, indexUrl);

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

/**
 * Parse meta paths from findlib_index to extract package info.
 *
 * Meta paths look like:
 *   ../../p/fmt/0.9.0/e6ef49d5/lib/fmt/META             → blessed: p/fmt/0.9.0
 *   ../../../u/9901393f/ocaml-compiler/5.4.0/d0f633/...  → universe: u/9901393f/ocaml-compiler/5.4.0
 *   ../../ocaml-base-compiler/5.0.0/943ab89d/...         → blessed (relative): p/ocaml-base-compiler/5.0.0
 */
function parseMetas(metas) {
  const packages = new Map(); // name → { version, path, hash }

  for (const meta of metas) {
    const parts = meta.split('/');

    // Find p/ or u/ marker in the path
    const pIdx = parts.indexOf('p');
    const uIdx = parts.indexOf('u');

    if (pIdx >= 0 && pIdx + 3 < parts.length) {
      // p/name/version/hash/...
      const name = parts[pIdx + 1];
      const version = parts[pIdx + 2];
      const hash = parts[pIdx + 3];
      if (!packages.has(name)) {
        packages.set(name, { version, path: `p/${name}/${version}`, hash });
      }
    } else if (uIdx >= 0 && uIdx + 4 < parts.length) {
      // u/universe_hash/name/version/hash/...
      const uHash = parts[uIdx + 1];
      const name = parts[uIdx + 2];
      const version = parts[uIdx + 3];
      const hash = parts[uIdx + 4];
      if (!packages.has(name)) {
        packages.set(name, { version, path: `u/${uHash.substring(0, 8)}\u2026/${name}/${version}`, hash, fullPath: `u/${uHash}/${name}/${version}` });
      }
    } else {
      // Relative blessed path: ../../name/version/hash/...
      // Find the pattern: skip leading ../ then name/version/hash/lib/...
      const nonDots = parts.filter(p => p !== '..');
      if (nonDots.length >= 3) {
        const name = nonDots[0];
        const version = nonDots[1];
        const hash = nonDots[2];
        if (!packages.has(name) && version.match(/^[\d.]+$|^base$/)) {
          packages.set(name, { version, path: `p/${name}/${version}`, hash });
        }
      }
    }
  }

  return packages;
}

/**
 * Render the dependency info section.
 */
function renderDeps(container, indexData, universeData, indexUrl) {
  const compiler = indexData.compiler;
  const metaPackages = parseMetas(indexData.metas || []);

  // Merge universe.json data (has all packages, even those without META)
  const allDeps = new Map();

  if (universeData) {
    for (const [name, version] of Object.entries(universeData)) {
      if (name === 'ocaml' || name === 'ocaml-config' || name.startsWith('base-')) continue;
      const fromMeta = metaPackages.get(name);
      allDeps.set(name, {
        version,
        path: fromMeta ? fromMeta.path : null,
        hash: fromMeta ? fromMeta.hash : null,
      });
    }
  } else {
    // No universe.json — use what we parsed from metas
    for (const [name, info] of metaPackages) {
      allDeps.set(name, info);
    }
  }

  // Worker.js info
  const workerInfo = el('div', { className: 'deps-worker' });
  workerInfo.innerHTML = `<strong>worker.js</strong>: compiler/${esc(compiler.version)}/${esc(compiler.content_hash)}/worker.js`;
  container.appendChild(workerInfo);

  // findlib_index source
  const indexInfo = el('div', { className: 'deps-index' });
  indexInfo.innerHTML = `<strong>findlib_index</strong>: ${esc(indexUrl.replace('/jtw-output/', ''))}`;
  container.appendChild(indexInfo);

  // Dependency table
  if (allDeps.size > 0) {
    const table = document.createElement('table');
    table.className = 'deps-table';
    table.innerHTML = '<thead><tr><th>Package</th><th>Version</th><th>Path</th></tr></thead>';
    const tbody = document.createElement('tbody');

    const sorted = [...allDeps.entries()].sort((a, b) => a[0].localeCompare(b[0]));
    for (const [name, info] of sorted) {
      const tr = document.createElement('tr');
      const pathDisplay = info.path || '\u2014';
      const hashBit = info.hash ? `<span class="deps-hash">${esc(info.hash.substring(0, 8))}\u2026</span>` : '';
      tr.innerHTML = `<td>${esc(name)}</td><td><code>${esc(info.version)}</code></td><td><code>${esc(pathDisplay)}</code> ${hashBit}</td>`;
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    container.appendChild(table);
  }
}

function splitPkg(pkg) {
  const i = pkg.indexOf('.');
  return [pkg.substring(0, i), pkg.substring(i + 1)];
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
