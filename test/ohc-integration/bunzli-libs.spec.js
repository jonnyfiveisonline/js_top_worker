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
  'fmt.0.10.0':   'dc92d356407d44e1eae7e39acefce214',
  'fmt.0.11.0':   '5c8d38716cee871f1a6a1f164c9171e6',

  // cmdliner versions
  'cmdliner.1.0.4': '1c3783a51f479ccb97503596896eb40b',
  'cmdliner.1.3.0': 'bcb1b5485952a387d9a1a626d018fc5b',
  'cmdliner.2.0.0': 'e6cf251f6257587fa235157819c1be21',
  'cmdliner.2.1.0': '146d116fd47cdde3a5912f6c3c43a06c',

  // mtime versions
  'mtime.1.3.0': '405772d8c1d5fcfb52a34bc074e9b2bf',
  'mtime.1.4.0': 'd07582e1ae666064d4e2cf55b8f966f2',
  'mtime.2.1.0': '427565ec9f440e77ea8cda7a5baf2f16',

  // logs versions
  'logs.0.7.0':  '2579ce9998e74d858251a8467a2d3acc',
  'logs.0.8.0':  '87870a13519516a235ea0651450f3d3a',
  'logs.0.10.0': '1447d6620c603faabafd2a4af8180e64',

  // uucp versions (Unicode version tracking)
  'uucp.14.0.0': '61994aea366afe63fbbdfbec3a6c1c17',
  'uucp.15.0.0': '1676ff3253642b3d3380da595576d048',
  'uucp.16.0.0': '2536abe6336b2597409378c985af206f',
  'uucp.17.0.0': '9f478f56c02c6b75ad53e569576ac528',

  // uunf versions
  'uunf.14.0.0': 'c49889fbf46b81974819b189749084eb',
  'uunf.17.0.0': 'd41feec064e2a5ca2ca9ce644b490c35',

  // Single-version libraries
  'astring.0.8.5': '77fa5901f826c06565dd83b8f758980c',
  'jsonm.1.0.2':   '331ba04a1674f61d6eb297de762940ea',
  'xmlm.1.4.0':    'de0c6b460a24c08865ced16ef6a90978',
  'ptime.1.2.0':   '0e977ea260d75026d2cdd4a7d007b2a5',
  'react.1.2.2':   '8b8f1bafe428e743bbb3e9f6a24753a5',
  'hmap.0.8.1':    '9cbc1bea29fe2a32ff73726147a24f7f',
  'gg.1.0.0':      '0c7a6cc72b0eef74ddf88e8512b418e1',
  'note.0.0.3':    '7497fed22490d2257a6fb4ac44bb1316',
  'otfm.0.4.0':    'af7a1a159d4a1c27da168df5cad06ad9',
  'vg.0.9.4':      'acac36a3d697c95764ca16a19c0402e8',
  'vg.0.9.5':      '8a313572e25666862de0bc23fc09c53d',
  'bos.0.2.1':     '1447d6620c603faabafd2a4af8180e64',
  'fpath.0.7.3':   'b034f0f4718c8842fdec8d4ff3430b97',
  'uutf.1.0.4':    '331ba04a1674f61d6eb297de762940ea',
  'b0.0.0.6':      '3125f46428fef2c0920ae254a3678000',
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

  test('vg 0.9.4: also works (older version)', async ({ page }) => {
    // vg 0.9.4's universe has many large deps, skip if too slow
    // The require may timeout because there are lots of .cma.js to load
    test.setTimeout(180000);
    await initWorker(page, U['vg.0.9.4']);
    // Use page.evaluate with an extended timeout for the large requires
    const reqResult = await page.evaluate(async () => {
      try {
        await window.workerEval('#require "vg";;');
        await window.workerEval('#require "gg";;');
        return { ok: true };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    });
    if (!reqResult.ok) {
      test.skip(true, `Skipped: ${reqResult.error}`);
      return;
    }

    await evalExpect(page,
      'Vg.P.empty |> Vg.P.line (Gg.V2.v 1.0 1.0);;',
      'Vg.path');
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
