// @ts-check
const { test, expect } = require('@playwright/test');

// ── Helpers ──────────────────────────────────────────────────────────────────

async function initWorkerBlessed(page, packageSpec, compiler) {
  const logs = [];
  page.on('console', msg => logs.push(msg.text()));

  const url = `/test/ohc-integration/eval-test.html?package=${packageSpec}` +
    (compiler ? `&compiler=${compiler}` : '');
  await page.goto(url);

  await expect(async () => {
    const ready = await page.locator('#status').getAttribute('data-ready');
    const error = await page.locator('#status').getAttribute('data-error');
    if (error) throw new Error(`Worker init failed: ${error}`);
    expect(ready).toBe('true');
  }).toPass({ timeout: 90000 });

  return { logs };
}

async function evalCode(page, code) {
  return await page.evaluate(async (c) => await window.workerEval(c), code);
}

async function requirePkg(page, pkg) {
  return await evalCode(page, `#require "${pkg}";;`);
}

async function evalExpect(page, code, expected) {
  const r = await evalCode(page, code);
  expect(r.caml_ppf).toContain(expected);
  return r;
}

// ── Tests using blessed package paths ────────────────────────────────────────

test.describe('JTW Worker Validation (blessed packages)', () => {
  test.setTimeout(120000);

  // ── OCaml 5.4.0 packages ──────────────────────────────────────────────────

  test('fmt 0.9.0: Fmt.str works (5.4.0)', async ({ page }) => {
    await initWorkerBlessed(page, 'fmt.0.9.0', '5.4.0');
    await requirePkg(page, 'fmt');
    await evalExpect(page, 'Fmt.str "%d" 42;;', '"42"');

    const r = await evalCode(page, 'Fmt.pr "hello %s" "world";;');
    expect(r.stdout).toContain('hello world');
  });

  test('menhirLib 20250912: module loads (5.4.0)', async ({ page }) => {
    await initWorkerBlessed(page, 'menhirLib.20250912', '5.4.0');
    const r = await requirePkg(page, 'menhirLib');
    expect(r.stderr).not.toContain('Cannot load');
    const r2 = await evalCode(page, 'MenhirLib.General.length;;');
    expect(r2.caml_ppf + r2.stderr).not.toContain('Unbound');
  });

  test('0install-solver 2.18: module loads (5.4.0)', async ({ page }) => {
    await initWorkerBlessed(page, '0install-solver.2.18', '5.4.0');
    const r = await requirePkg(page, '0install-solver');
    expect(r.stderr).not.toContain('Cannot load');
    const r2 = await evalCode(page, 'Zeroinstall_solver.Diagnostics.of_result;;');
    expect(r2.caml_ppf + r2.stderr).not.toContain('Unbound');
  });

  // ── OCaml 5.3.0 packages ──────────────────────────────────────────────────

  test('containers 3.14: CCList and CCString work (5.3.0)', async ({ page }) => {
    await initWorkerBlessed(page, 'containers.3.14', '5.3.0');
    await requirePkg(page, 'containers');
    await evalExpect(page,
      'CCList.filter_map (fun x -> if x > 2 then Some (x * 10) else None) [1;2;3;4];;',
      '[30; 40]');
    await evalExpect(page,
      'CCString.prefix ~pre:"hello" "hello world";;',
      'true');
  });

  // ── OCaml 5.2.1 packages ──────────────────────────────────────────────────

  test('batteries 3.8.0: BatList works (5.2.1)', async ({ page }) => {
    await initWorkerBlessed(page, 'batteries.3.8.0', '5.2.1');
    await requirePkg(page, 'batteries');
    await evalExpect(page,
      'BatList.filter_map (fun x -> if x > 2 then Some (x*10) else None) [1;2;3;4;5];;',
      '[30; 40; 50]');
  });

  test('extlib 1.7.9: ExtList.List.unique (5.2.1)', async ({ page }) => {
    await initWorkerBlessed(page, 'extlib.1.7.9', '5.2.1');
    await requirePkg(page, 'extlib');
    await evalExpect(page,
      'ExtList.List.unique [1;2;2;3;3;3;4];;',
      '[1; 2; 3; 4]');
  });

  // ── OCaml 5.1.1 packages ──────────────────────────────────────────────────

  test('batteries 3.7.2: BatString works (5.1.1)', async ({ page }) => {
    await initWorkerBlessed(page, 'batteries.3.7.2', '5.1.1');
    await requirePkg(page, 'batteries');
    await evalExpect(page,
      'BatString.starts_with "hello world" "hello";;',
      'true');
  });

  test('stdcompat 19: Stdcompat.List works (5.1.1)', async ({ page }) => {
    await initWorkerBlessed(page, 'stdcompat.19', '5.1.1');
    await requirePkg(page, 'stdcompat');
    await evalExpect(page,
      'Stdcompat.List.filter_map (fun x -> if x > 3 then Some x else None) [1;2;3;4;5];;',
      '[4; 5]');
  });

  // ── OCaml 5.0.0 packages ──────────────────────────────────────────────────

  test('batteries 3.6.0: basic eval works (5.0.0)', async ({ page }) => {
    await initWorkerBlessed(page, 'batteries.3.6.0', '5.0.0');
    await evalExpect(page, '1 + 1;;', '2');
    await evalExpect(page, 'List.map (fun x -> x * 2) [1;2;3];;', '[2; 4; 6]');
  });

  test('grenier 0.14: Dbseq module loads (5.0.0)', async ({ page }) => {
    await initWorkerBlessed(page, 'grenier.0.14', '5.0.0');
    await requirePkg(page, 'grenier.dbseq');
    await evalExpect(page, 'Dbseq.empty |> Dbseq.length;;', '0');
  });

  // ── OCaml 4.14.2 packages ─────────────────────────────────────────────────

  test('olinq 0.3: LINQ-style queries (4.14.2)', async ({ page }) => {
    await initWorkerBlessed(page, 'olinq.0.3', '4.14.2');
    await requirePkg(page, 'olinq');
    await evalExpect(page,
      'OLinq.of_list [1;2;3;4;5] |> OLinq.filter (fun x -> x > 2) |> OLinq.run_list;;',
      '[3; 4; 5]');
  });

  test('hamt 1.0.0: hash array mapped trie (4.14.2)', async ({ page }) => {
    await initWorkerBlessed(page, 'hamt.1.0.0', '4.14.2');
    await requirePkg(page, 'hamt');
    await evalExpect(page,
      'Hamt.Int.(add 1 "hello" empty |> add 2 "world" |> find_exn 1);;',
      '"hello"');
  });

  test('vlq 0.2.1: variable-length quantity encoding (4.14.2)', async ({ page }) => {
    await initWorkerBlessed(page, 'vlq.0.2.1', '4.14.2');
    await requirePkg(page, 'vlq');
    await evalExpect(page,
      'let buf = Buffer.create 10 in Vlq.Base64.encode buf 0; Buffer.contents buf;;',
      '"A"');
  });

  test('wamp 1.2: WAMP protocol types (4.14.2)', async ({ page }) => {
    await initWorkerBlessed(page, 'wamp.1.2', '4.14.2');
    const r = await requirePkg(page, 'wamp');
    expect(r.stderr).not.toContain('Cannot load');
    await evalExpect(page,
      'List.length [Wamp.Subscriber; Wamp.Publisher];;',
      '2');
  });

  test('wseg 0.3.0: word segmentation (4.14.2)', async ({ page }) => {
    await initWorkerBlessed(page, 'wseg.0.3.0', '4.14.2');
    const r = await requirePkg(page, 'wseg');
    expect(r.stderr).not.toContain('Cannot load');
    await evalExpect(page,
      'let entries = Wseg.Dict.buildEntries [("a", 3.0); ("b", 7.0)] in List.length entries;;',
      '2');
  });

  test('angstrom 0.16.1: parser combinators (4.14.2)', async ({ page }) => {
    await initWorkerBlessed(page, 'angstrom.0.16.1', '4.14.2');
    await requirePkg(page, 'angstrom');
    await evalExpect(page,
      'Angstrom.(parse_string ~consume:All (string "hello") "hello");;',
      'Ok "hello"');
  });

  test('uri 4.4.0: URI parsing (4.14.2)', async ({ page }) => {
    await initWorkerBlessed(page, 'uri.4.4.0', '4.14.2');
    await requirePkg(page, 'uri');
    await evalExpect(page,
      'Uri.of_string "https://example.com:8080/path?q=1" |> Uri.host;;',
      'Some "example.com"');
  });
});
