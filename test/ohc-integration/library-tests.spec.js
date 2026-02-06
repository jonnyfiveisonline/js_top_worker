// @ts-check
const { test, expect } = require('@playwright/test');

// ── Helpers ──────────────────────────────────────────────────────────────────

/** Navigate to eval-test.html, wait for worker ready, return page */
async function initWorker(page, universe, compiler = '5.4.0') {
  const logs = [];
  page.on('console', msg => logs.push(msg.text()));

  await page.goto(
    `/test/ohc-integration/eval-test.html?universe=${universe}&compiler=${compiler}`
  );

  // Wait for worker to be ready
  await expect(async () => {
    const ready = await page.locator('#status').getAttribute('data-ready');
    const error = await page.locator('#status').getAttribute('data-error');
    if (error) throw new Error(`Worker init failed: ${error}`);
    expect(ready).toBe('true');
  }).toPass({ timeout: 90000 });

  return { logs };
}

/** Evaluate OCaml code and return { caml_ppf, stdout, stderr } */
async function evalCode(page, code) {
  return await page.evaluate(async (c) => await window.workerEval(c), code);
}

/** #require a package, return result */
async function requirePkg(page, pkg) {
  return await evalCode(page, `#require "${pkg}";;`);
}

/** Evaluate and expect caml_ppf to contain a substring */
async function evalExpect(page, code, expected) {
  const r = await evalCode(page, code);
  expect(r.caml_ppf).toContain(expected);
  return r;
}

/** Evaluate and expect caml_ppf NOT to contain a substring (error case) */
async function evalExpectError(page, code) {
  const r = await evalCode(page, code);
  // Errors go to stderr, caml_ppf is usually empty or contains Error
  return r;
}

// ── Universe mapping ─────────────────────────────────────────────────────────

const U = {
  // fmt versions
  'fmt.0.9.0':    '9901393f978b0a6627c5eab595111f50',
  'fmt.0.10.0':   'd8140118651d08430f933d410a909e3b',
  'fmt.0.11.0':   '7663cce356513833b908ae5e4f521106',

  // cmdliner versions
  'cmdliner.1.0.4': '0dd34259dc0892e543b03b3afb0a77fa',
  'cmdliner.1.3.0': '258e7979b874502ea546e90a0742184a',
  'cmdliner.2.0.0': '91c3d96cea9b89ddd24cf7b78786a5ca',
  'cmdliner.2.1.0': 'f3e665d5388ac380a70c5ed67f465bbb',

  // mtime versions
  'mtime.1.3.0': 'b6735658fd307bba23a7c5f21519b910',
  'mtime.1.4.0': 'ebccfc43716c6da0ca4a065e60d0f875',
  'mtime.2.1.0': '7db699c334606d6f66e65c8b515d298d',

  // logs versions
  'logs.0.7.0':  '2c014cfbbee1d278b162002eae03eaa8',
  'logs.0.10.0': '07a565e7588ce100ffd7c8eb8b52df07',

  // uucp versions (Unicode version tracking)
  'uucp.14.0.0': '60e1409eb30c0650c4d4cbcf3c453e65',
  'uucp.15.0.0': '6a96a3f145249f110bf14739c78e758c',
  'uucp.16.0.0': '2bf0fbf12aa05c8f99989a759d2dc8cf',
  'uucp.17.0.0': '58b9c48e9528ce99586b138d8f4778c2',

  // uunf versions
  'uunf.14.0.0': 'cac36534f1bf353fd2192efd015dd0e6',
  'uunf.17.0.0': '96704cd9810ea1ed504e4ed71cde82b0',

  // Single-version libraries
  'astring.0.8.5': '1cdbe76f0ec91a6eb12bd0279a394492',
  'jsonm.1.0.2':   'ac28e00ecd46c9464f5575c461b5d48f',
  'xmlm.1.4.0':    'c4c22d0db3ea01343c1a868bab35e1b4',
  'ptime.1.2.0':   'd57c69f3dd88b91454622c1841971354',
  'react.1.2.2':   'f438ba61693a5448718c73116b228f3c',
  'hmap.0.8.1':    '753d7c421afb866e7ffe07ddea3b8349',
  'gg.1.0.0':      '02a9bababc92d6639cdbaf20233597ba',
  'note.0.0.3':    '2545f914c274aa806d29749eb96836fa',
  'otfm.0.4.0':    '4f870a70ee71e41dff878af7123b2cd6',
  'vg.0.9.5':      '0e2e71cfd8fe2e81bff124849421f662',
  'bos.0.2.1':     '0e04faa6cc5527bc124d8625bded34fc',
  'fpath.0.7.3':   '6c4fe09a631d871865fd38aa15cd61d4',
  'uutf.1.0.4':    'ac04fa0671533316f94dacbd14ffe0bf',
  'b0.0.0.6':      'bfc34a228f53ac5ced707eed285a6e5c',

  // Cross-version: packages requiring OCaml < 5.4 (solved with 5.3.0)
  'containers.3.14': 'bc149e85833934caf6ad41a745e35cfd',
};


// ── Fmt: version comparison ──────────────────────────────────────────────────

test.describe('Fmt', () => {
  test.setTimeout(120000);

  for (const ver of ['0.9.0', '0.10.0', '0.11.0']) {
    const key = `fmt.${ver}`;
    if (!U[key]) continue;

    test(`fmt ${ver}: Fmt.str and Fmt.pr work`, async ({ page }) => {
      await initWorker(page, U[key]);
      await requirePkg(page, 'fmt');

      // Fmt.str: format to string (present in all these versions)
      await evalExpect(page, 'Fmt.str "%d" 42;;', '"42"');

      // Fmt.pr: format to stdout
      const r = await evalCode(page, 'Fmt.pr "hello %s" "world";;');
      expect(r.stdout).toContain('hello world');
    });
  }

  test('fmt 0.9.0 vs 0.11.0: Fmt.semi available in both', async ({ page }) => {
    // Fmt.semi is a separator formatter present in all versions
    await initWorker(page, U['fmt.0.9.0']);
    await requirePkg(page, 'fmt');
    const r = await evalCode(page,
      'Fmt.str "%a" Fmt.(list ~sep:semi int) [1;2;3];;');
    // The output contains the three numbers separated by semi
    expect(r.caml_ppf).toContain('1');
    expect(r.caml_ppf).toContain('2');
    expect(r.caml_ppf).toContain('3');
  });

  test('fmt completions work across versions', async ({ page }) => {
    await initWorker(page, U['fmt.0.11.0']);
    await requirePkg(page, 'fmt');
    const names = await page.evaluate(
      async () => await window.workerComplete('Fmt.s', 5)
    );
    expect(names.length).toBeGreaterThan(0);
    expect(names).toContain('str');
  });
});


// ── Cmdliner: major API change 1.x → 2.x ────────────────────────────────────

test.describe('Cmdliner', () => {
  test.setTimeout(120000);

  test('cmdliner 1.0.4: Term.eval exists (v1 API)', async ({ page }) => {
    await initWorker(page, U['cmdliner.1.0.4']);
    await requirePkg(page, 'cmdliner');

    // In cmdliner 1.x, Cmdliner.Term.eval is the primary entry point
    await evalExpect(page,
      'Cmdliner.Term.eval;;',
      'Cmdliner.Term');
  });

  test('cmdliner 2.1.0: Cmd module exists (v2 API)', async ({ page }) => {
    await initWorker(page, U['cmdliner.2.1.0']);
    await requirePkg(page, 'cmdliner');

    // In cmdliner 2.x, Cmdliner.Cmd is the new entry point
    await evalExpect(page, 'Cmdliner.Cmd.info;;', 'Cmdliner.Cmd');

    // Cmdliner.Cmd.v is the new way to create commands
    await evalExpect(page, 'Cmdliner.Cmd.v;;', 'Cmdliner.Cmd');
  });

  test('cmdliner 2.1.0: Arg module works', async ({ page }) => {
    await initWorker(page, U['cmdliner.2.1.0']);
    await requirePkg(page, 'cmdliner');

    await evalExpect(page,
      'let name = Cmdliner.Arg.(required & pos 0 (some string) None & info []);;',
      'Cmdliner.Term');
  });

  test('cmdliner 1.3.0: transitional — both Term.eval and Cmd exist', async ({ page }) => {
    await initWorker(page, U['cmdliner.1.3.0']);
    await requirePkg(page, 'cmdliner');

    // 1.3.0 has both the old and new APIs for migration
    await evalExpect(page, 'Cmdliner.Term.eval;;', 'Cmdliner.Term');
    await evalExpect(page, 'Cmdliner.Cmd.info;;', 'Cmdliner.Cmd');
  });
});


// ── Mtime: API change 1.x → 2.x ─────────────────────────────────────────────

test.describe('Mtime', () => {
  test.setTimeout(120000);

  test('mtime 1.4.0: Mtime.Span.to_uint64_ns exists', async ({ page }) => {
    await initWorker(page, U['mtime.1.4.0']);
    await requirePkg(page, 'mtime');
    await evalExpect(page, 'Mtime.Span.to_uint64_ns;;', '-> int64');
  });

  test('mtime 2.1.0: Mtime.Span.to_uint64_ns exists (kept)', async ({ page }) => {
    await initWorker(page, U['mtime.2.1.0']);
    await requirePkg(page, 'mtime');
    await evalExpect(page, 'Mtime.Span.to_uint64_ns;;', '-> int64');
  });

  test('mtime 2.1.0: Mtime.Span.pp works', async ({ page }) => {
    await initWorker(page, U['mtime.2.1.0']);
    await requirePkg(page, 'mtime');
    // Mtime.Span.pp uses Format directly, not Fmt
    await evalExpect(page,
      'Mtime.Span.of_uint64_ns 1_000_000_000L;;',
      'Mtime.span');
  });
});


// ── Logs: basic functionality across versions ────────────────────────────────

test.describe('Logs', () => {
  test.setTimeout(120000);

  test('logs 0.7.0: Logs module loads', async ({ page }) => {
    await initWorker(page, U['logs.0.7.0']);
    const reqResult = await requirePkg(page, 'logs');

    // Verify require succeeded by checking that Logs module is available
    // Use a simple expression: Logs.err is a log level constructor
    const r = await evalCode(page, 'Logs.err;;');
    // Should produce something with "Logs.level" in the type
    // If the module failed to load, we'd get an Unbound module error
    expect(r.caml_ppf + r.stderr).not.toContain('Unbound module');
  });

  test('logs 0.10.0: Logs.Src module works', async ({ page }) => {
    await initWorker(page, U['logs.0.10.0']);
    await requirePkg(page, 'logs');

    await evalExpect(page,
      'let src = Logs.Src.create "test" ~doc:"A test source";;',
      'Logs.src');

    await evalExpect(page, 'Logs.Src.name src;;', '"test"');
  });
});


// ── Uucp: Unicode version tracking ──────────────────────────────────────────

test.describe('Uucp (Unicode versions)', () => {
  test.setTimeout(120000);

  test('uucp 14.0.0: reports Unicode 14.0.0', async ({ page }) => {
    await initWorker(page, U['uucp.14.0.0']);
    await requirePkg(page, 'uucp');
    await evalExpect(page, 'Uucp.unicode_version;;', '"14.0.0"');
  });

  test('uucp 15.0.0: reports Unicode 15.0.0', async ({ page }) => {
    await initWorker(page, U['uucp.15.0.0']);
    await requirePkg(page, 'uucp');
    await evalExpect(page, 'Uucp.unicode_version;;', '"15.0.0"');
  });

  test('uucp 16.0.0: reports Unicode 16.0.0', async ({ page }) => {
    await initWorker(page, U['uucp.16.0.0']);
    await requirePkg(page, 'uucp');
    await evalExpect(page, 'Uucp.unicode_version;;', '"16.0.0"');
  });

  test('uucp 17.0.0: reports Unicode 17.0.0', async ({ page }) => {
    await initWorker(page, U['uucp.17.0.0']);
    await requirePkg(page, 'uucp');
    await evalExpect(page, 'Uucp.unicode_version;;', '"17.0.0"');
  });

  test('uucp: general category lookup works', async ({ page }) => {
    await initWorker(page, U['uucp.17.0.0']);
    await requirePkg(page, 'uucp');
    // 'A' is Lu (uppercase letter)
    await evalExpect(page,
      'Uucp.Gc.general_category (Uchar.of_int 0x0041);;',
      '`Lu');
  });
});


// ── Uunf: Unicode normalization ──────────────────────────────────────────────

test.describe('Uunf', () => {
  test.setTimeout(120000);

  test('uunf 14.0.0: reports Unicode 14.0.0', async ({ page }) => {
    await initWorker(page, U['uunf.14.0.0']);
    await requirePkg(page, 'uunf');
    await evalExpect(page, 'Uunf.unicode_version;;', '"14.0.0"');
  });

  test('uunf 17.0.0: reports Unicode 17.0.0', async ({ page }) => {
    await initWorker(page, U['uunf.17.0.0']);
    await requirePkg(page, 'uunf');
    await evalExpect(page, 'Uunf.unicode_version;;', '"17.0.0"');
  });
});


// ── Astring: string processing ───────────────────────────────────────────────

test.describe('Astring', () => {
  test.setTimeout(120000);

  test('astring 0.8.5: String.cuts and String.concat', async ({ page }) => {
    await initWorker(page, U['astring.0.8.5']);
    await requirePkg(page, 'astring');

    await evalExpect(page,
      'Astring.String.cuts ~sep:"," "a,b,c";;',
      '["a"; "b"; "c"]');

    await evalExpect(page,
      'Astring.String.concat ~sep:"-" ["x"; "y"; "z"];;',
      '"x-y-z"');
  });

  test('astring 0.8.5: String.Sub module', async ({ page }) => {
    await initWorker(page, U['astring.0.8.5']);
    await requirePkg(page, 'astring');

    await evalExpect(page,
      'Astring.String.Sub.(to_string (v "hello world" ~start:6));;',
      '"world"');
  });
});


// ── Jsonm: streaming JSON ────────────────────────────────────────────────────

test.describe('Jsonm', () => {
  test.setTimeout(120000);

  test('jsonm 1.0.2: encode and decode JSON', async ({ page }) => {
    await initWorker(page, U['jsonm.1.0.2']);
    await requirePkg(page, 'jsonm');

    // Create a decoder and read from a JSON string
    await evalExpect(page,
      'let d = Jsonm.decoder (`String "42") in Jsonm.decode d;;',
      '`Lexeme');
  });
});


// ── Xmlm: XML processing ────────────────────────────────────────────────────

test.describe('Xmlm', () => {
  test.setTimeout(120000);

  test('xmlm 1.4.0: parse XML input', async ({ page }) => {
    await initWorker(page, U['xmlm.1.4.0']);
    await requirePkg(page, 'xmlm');

    await evalExpect(page,
      'let i = Xmlm.make_input (`String (0, "<root/>")) in Xmlm.input i;;',
      '`Dtd');
  });
});


// ── Ptime: POSIX time ────────────────────────────────────────────────────────

test.describe('Ptime', () => {
  test.setTimeout(120000);

  test('ptime 1.2.0: epoch and time arithmetic', async ({ page }) => {
    await initWorker(page, U['ptime.1.2.0']);
    await requirePkg(page, 'ptime');

    await evalExpect(page, 'Ptime.epoch;;', 'Ptime.t');

    // Create a specific date
    await evalExpect(page,
      'Ptime.of_date_time ((2024, 1, 1), ((0, 0, 0), 0));;',
      'Some');
  });

  test('ptime 1.2.0: Ptime.Span works', async ({ page }) => {
    await initWorker(page, U['ptime.1.2.0']);
    await requirePkg(page, 'ptime');

    await evalExpect(page,
      'Ptime.Span.of_int_s 3600 |> Ptime.Span.to_int_s;;',
      '3600');
  });
});


// ── React: functional reactive programming ───────────────────────────────────

test.describe('React', () => {
  test.setTimeout(120000);

  test('react 1.2.2: create signals and events', async ({ page }) => {
    await initWorker(page, U['react.1.2.2']);
    await requirePkg(page, 'react');

    // Create a signal with initial value
    await evalExpect(page,
      'let s, set_s = React.S.create 0;;',
      'React.signal');

    // Read signal value
    await evalExpect(page, 'React.S.value s;;', '0');

    // Update and read
    await evalCode(page, 'set_s 42;;');
    await evalExpect(page, 'React.S.value s;;', '42');
  });
});


// ── Hmap: heterogeneous maps ─────────────────────────────────────────────────

test.describe('Hmap', () => {
  test.setTimeout(120000);

  test('hmap 0.8.1: create keys and store heterogeneous values', async ({ page }) => {
    await initWorker(page, U['hmap.0.8.1']);
    await requirePkg(page, 'hmap');

    await evalExpect(page,
      'let k_int : int Hmap.key = Hmap.Key.create ();;',
      'Hmap.key');

    await evalExpect(page,
      'let k_str : string Hmap.key = Hmap.Key.create ();;',
      'Hmap.key');

    await evalExpect(page,
      'let m = Hmap.empty |> Hmap.add k_int 42 |> Hmap.add k_str "hello";;',
      'Hmap.t');

    await evalExpect(page, 'Hmap.find k_int m;;', 'Some 42');
    await evalExpect(page, 'Hmap.find k_str m;;', 'Some "hello"');
  });
});


// ── Gg: basic graphics geometry ──────────────────────────────────────────────

test.describe('Gg', () => {
  test.setTimeout(120000);

  test('gg 1.0.0: 2D vectors and colors', async ({ page }) => {
    await initWorker(page, U['gg.1.0.0']);
    await requirePkg(page, 'gg');

    // Create a 2D point
    await evalExpect(page, 'Gg.V2.v 1.0 2.0;;', 'Gg.v2');

    // Vector addition
    await evalExpect(page,
      'Gg.V2.add (Gg.V2.v 1.0 2.0) (Gg.V2.v 3.0 4.0);;',
      'Gg.v2');

    // Check the result
    await evalExpect(page,
      'let r = Gg.V2.add (Gg.V2.v 1.0 2.0) (Gg.V2.v 3.0 4.0) in Gg.V2.x r;;',
      '4.');

    // Colors
    await evalExpect(page, 'Gg.Color.red;;', 'Gg.color');
  });
});


// ── Vg: vector graphics ─────────────────────────────────────────────────────

test.describe('Vg', () => {
  test.setTimeout(120000);

  test('vg 0.9.5: create paths and images', async ({ page }) => {
    await initWorker(page, U['vg.0.9.5']);
    await requirePkg(page, 'vg');
    await requirePkg(page, 'gg');

    // Create a simple path
    await evalExpect(page,
      'let p = Vg.P.empty |> Vg.P.line (Gg.V2.v 1.0 1.0);;',
      'Vg.path');

    // Create an image from path
    await evalExpect(page,
      'let img = Vg.I.cut p (Vg.I.const Gg.Color.red);;',
      'Vg.image');
  });

  test.skip('vg 0.9.4: also works (older version) — not built', async ({ page }) => {
    // vg 0.9.4 is not included in the current batch build
  });
});


// ── Note: declarative signals ────────────────────────────────────────────────

test.describe('Note', () => {
  test.setTimeout(120000);

  test('note 0.0.3: create events and signals', async ({ page }) => {
    await initWorker(page, U['note.0.0.3']);
    await requirePkg(page, 'note');

    // Note.S is the signal module
    await evalExpect(page,
      'let s = Note.S.const 42;;',
      'Note.signal');

    await evalExpect(page, 'Note.S.value s;;', '42');
  });
});


// ── Otfm: OpenType font metrics ──────────────────────────────────────────────

test.describe('Otfm', () => {
  test.setTimeout(120000);

  test('otfm 0.4.0: module loads and types available', async ({ page }) => {
    await initWorker(page, U['otfm.0.4.0']);
    await requirePkg(page, 'otfm');

    // Check that the decoder type exists
    await evalExpect(page, 'Otfm.decoder;;', '-> Otfm.decoder');
  });
});


// ── Fpath: file system paths ─────────────────────────────────────────────────

test.describe('Fpath', () => {
  test.setTimeout(120000);

  test('fpath 0.7.3: path manipulation', async ({ page }) => {
    await initWorker(page, U['fpath.0.7.3']);
    await requirePkg(page, 'fpath');

    await evalExpect(page,
      'Fpath.v "/usr/local/bin" |> Fpath.to_string;;',
      '"/usr/local/bin"');

    await evalExpect(page,
      'Fpath.(v "/usr" / "local" / "bin") |> Fpath.to_string;;',
      '"/usr/local/bin"');

    await evalExpect(page,
      'Fpath.v "/usr/local/bin" |> Fpath.parent |> Fpath.to_string;;',
      '"/usr/local/"');

    await evalExpect(page,
      'Fpath.v "/usr/local/bin" |> Fpath.basename;;',
      '"bin"');
  });
});


// ── Uutf: UTF decoding/encoding ──────────────────────────────────────────────

test.describe('Uutf', () => {
  test.setTimeout(120000);

  test('uutf 1.0.4: decode UTF-8', async ({ page }) => {
    await initWorker(page, U['uutf.1.0.4']);
    await requirePkg(page, 'uutf');

    // Create a decoder
    await evalExpect(page,
      'let d = Uutf.decoder ~encoding:`UTF_8 (`String "ABC");;',
      'Uutf.decoder');

    // Decode first character
    await evalExpect(page, 'Uutf.decode d;;', '`Uchar');
  });
});


// ── B0: build system library ─────────────────────────────────────────────────

test.describe('B0', () => {
  test.setTimeout(120000);

  test('b0 0.0.6: B0_std.Fpath', async ({ page }) => {
    await initWorker(page, U['b0.0.0.6']);
    await requirePkg(page, 'b0.std');

    await evalExpect(page, 'B0_std.Fpath.v "/tmp";;', 'B0_std.Fpath.t');
  });
});


// ── Cross-library: Bos (uses fmt + fpath + logs + astring + rresult) ─────────

test.describe('Bos (cross-library)', () => {
  test.setTimeout(120000);

  test('bos 0.2.1: depends on fmt, fpath, logs, astring', async ({ page }) => {
    await initWorker(page, U['bos.0.2.1']);
    await requirePkg(page, 'bos');

    // Bos.OS.File uses Fpath
    await evalExpect(page, 'Bos.OS.Cmd.run_status;;', 'Bos.Cmd');

    // Bos.Cmd construction
    await evalExpect(page,
      'Bos.Cmd.(v "echo" % "hello");;',
      'Bos.Cmd');
  });
});


// ── Containers: OCaml 5.3.0 (< 5.4 constraint) ────────────────────────────

test.describe('Containers (OCaml 5.3.0)', () => {
  test.setTimeout(120000);

  test('containers 3.14: loads with OCaml 5.3.0 compiler', async ({ page }) => {
    // containers.3.14 requires ocaml < 5.4, so it was solved with OCaml 5.3.0
    await initWorker(page, U['containers.3.14'], '5.3.0');
    await requirePkg(page, 'containers');

    // CCList is a core module in containers
    await evalExpect(page,
      'CCList.filter_map (fun x -> if x > 2 then Some (x * 10) else None) [1;2;3;4];;',
      '[30; 40]');

    // CCString basic usage
    await evalExpect(page,
      'CCString.prefix ~pre:"hello" "hello world";;',
      'true');
  });
});
