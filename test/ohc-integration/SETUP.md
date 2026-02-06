# OHC Integration Demos & Tutorials — Setup Guide

## Overview

This directory contains browser-based demos that run OCaml code in a web worker,
loading real opam packages compiled to JavaScript. The tutorials cover 30 versions
of Daniel Bunzli's OCaml libraries with interactive, step-by-step examples.

## Prerequisites

- **day10** (formerly ohc) — the build tool that produces JTW artifacts
- **js_top_worker** — this repo, providing the client library and worker
- **Python 3** — for serving files over HTTP
- **Node.js + npm** — for running Playwright tests (optional)

## Repositories & Commits

| Repo | URL | Branch | Commit |
|------|-----|--------|--------|
| **day10** | `git@github.com:jonludlam/ohc` | `feature/jtw-support` | `e6fb848` |
| **js_top_worker** | `https://github.com/jonnyfiveisonline/js_top_worker` | `enhancements` | `538ab03` |

## Step 1: Build js_top_worker

```bash
git clone https://github.com/jonnyfiveisonline/js_top_worker.git
cd js_top_worker
git checkout enhancements
dune build
```

This produces `_build/default/client/ocaml-worker.js` — the browser client library.

Create a convenience symlink (if not already present):

```bash
ln -sf _build/default/client client
```

## Step 2: Build JTW Output with day10

day10 builds opam packages and compiles them to JavaScript artifacts that the
browser worker can load.

```bash
git clone git@github.com:jonludlam/ohc day10
cd day10
git checkout feature/jtw-support  # commit e6fb848
opam install dockerfile ppx_deriving_yojson opam-0install
dune build bin/main.exe
```

### Run a health-check for a single package

```bash
./day10 health-check --with-jtw --jtw-output /path/to/jtw-output fmt
```

### Run a batch build for all Bunzli libraries

Create a batch file `bunzli.txt` with one package per line:

```
fmt
cmdliner
mtime
logs
uucp
uunf
astring
jsonm
xmlm
ptime
react
hmap
gg
vg
note
otfm
fpath
uutf
b0
bos
```

Then run:

```bash
./day10 batch --with-jtw --jtw-output /path/to/jtw-output bunzli.txt
```

This produces the JTW output directory with the structure:

```
jtw-output/
  compiler/
    5.4.0/
      worker.js                    # OCaml toplevel worker (~21MB)
      lib/ocaml/
        dynamic_cmis.json          # Stdlib module index
        *.cmi, stdlib.cma.js       # Stdlib artifacts
  u/<universe-hash>/               # One per (package, version) universe
    findlib_index                  # JSON: list of META file paths
    <pkg>/<ver>/lib/<findlib>/     # Package artifacts
      META, *.cmi, *.cma.js, dynamic_cmis.json
  p/<pkg>/<ver>/lib/...            # Blessed packages (same structure)
```

## Step 3: Symlink JTW Output into js_top_worker

```bash
cd /path/to/js_top_worker
ln -sf /path/to/jtw-output jtw-output
```

## Step 4: Start the HTTP Server

```bash
cd /path/to/js_top_worker
python3 -m http.server 8769
```

## Step 5: Open in Browser

| Page | URL |
|------|-----|
| **Tutorial index** | http://localhost:8769/test/ohc-integration/tutorials/index.html |
| **Single tutorial** | http://localhost:8769/test/ohc-integration/tutorials/tutorial.html?pkg=fmt.0.11.0 |
| **Test runner** | http://localhost:8769/test/ohc-integration/runner.html |
| **Basic eval test** | http://localhost:8769/test/ohc-integration/test.html?universe=HASH |

The tutorial index page lists all 30 library-version tutorials grouped by library.
Click any version card to open its interactive tutorial.

## Step 6: Run Automated Tests (Optional)

```bash
cd /path/to/js_top_worker/test/ohc-integration
npm install
npx playwright install chromium
npx playwright test tutorials/tutorials.spec.js   # 31 tutorial tests
npx playwright test bunzli-libs.spec.js            # 37 library tests
npx playwright test                                # all tests
```

## Available Tutorials

| Library | Versions | Topics |
|---------|----------|--------|
| Fmt | 0.9.0, 0.10.0, 0.11.0 | String formatting, typed formatters, collections, combinators |
| Cmdliner | 1.0.4, 1.3.0, 2.0.0, 2.1.0 | Argument building, Term API (v1), Cmd API (v2), custom converters |
| Mtime | 1.3.0, 1.4.0, 2.1.0 | Span constants, arithmetic, float conversions, API evolution |
| Logs | 0.10.0 | Log sources, level management, error tracking |
| Uucp | 14.0.0, 15.0.0, 16.0.0, 17.0.0 | Unicode properties, general category, script detection |
| Uunf | 14.0.0, 17.0.0 | Unicode normalization forms (NFC/NFD/NFKC/NFKD) |
| Astring | 0.8.5 | Splitting, building, testing, trimming, substrings |
| Jsonm | 1.0.2 | Streaming JSON decode/encode |
| Xmlm | 1.4.0 | Streaming XML parse/output |
| Ptime | 1.2.0 | POSIX timestamps, arithmetic, RFC 3339 formatting |
| React | 1.2.2 | FRP signals, events, derived signals |
| Hmap | 0.8.1 | Type-safe heterogeneous maps |
| Gg | 1.0.0 | 2D/3D vectors, colors, arithmetic |
| Vg | 0.9.5 | Declarative 2D vector graphics |
| Note | 0.0.3 | Reactive signals, transformations |
| Otfm | 0.4.0 | OpenType font decoder |
| Fpath | 0.7.3 | File system path manipulation |
| Uutf | 1.0.4 | UTF-8 streaming codec |
| B0 | 0.0.6 | File paths (B0_std.Fpath), command lines (B0_std.Cmd) |
| Bos | 0.2.1 | OS command construction, conditional args |

## Universe Hashes

Each (package, version) maps to a universe hash that identifies the exact set of
dependencies. These are defined in `tutorials/test-defs.js` and `runner.html`.
The hashes are deterministic — they will be the same on any machine that builds
the same package version with day10.

## Troubleshooting

- **"Failed to initialize"**: Check that `jtw-output/compiler/5.4.0/worker.js` exists
  and the HTTP server root is the js_top_worker repo root.
- **"inconsistent assumptions over interface"**: The package's build universe has
  a cmi mismatch. Rebuild with day10. (Known issue: logs 0.7.0)
- **Timeout loading packages**: Some large packages (uucp, gg, vg) take several
  seconds to load. The default timeout is 120 seconds.
- **Port conflict**: Change the port in the `python3 -m http.server` command.
  For Playwright tests, also update `playwright.config.js`.
