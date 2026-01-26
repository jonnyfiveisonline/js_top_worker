# js_top_worker Demo

This directory contains a comprehensive demo showcasing all features of js_top_worker - an OCaml toplevel that runs in a browser WebWorker.

## Features Demonstrated

- **Basic Execution**: Run OCaml code and see results
- **Multiple Environments**: Create isolated execution contexts
- **MIME Output**: Rich output (HTML, SVG, images) via `Mime_printer`
- **Autocomplete**: Code completion suggestions
- **Type Information**: Hover-style type queries
- **Error Reporting**: Static analysis and error detection
- **Directives**: `#show`, `#install_printer`, `#help`, etc.
- **Custom Printers**: Install custom value formatters
- **Library Loading**: Dynamic `#require` for findlib packages
- **Toplevel Scripts**: Execute multi-phrase scripts

## Prerequisites

You need:
- OCaml 5.2+ with opam
- The following opam packages installed:
  - js_of_ocaml, js_of_ocaml-ppx
  - dune (3.0+)
  - All js_top_worker dependencies

## Quick Start

### 1. Build the Project

From the repository root:

```bash
# Install dependencies (if not already done)
opam install . --deps-only

# Build everything
dune build
```

### 2. Prepare the Example Directory

The build generates the `_opam` directory with compiled libraries:

```bash
# This is done automatically by dune, but you can also run manually:
dune build @example/default
```

This creates `_build/default/example/_opam/` containing:
- `worker.js` - The WebWorker toplevel
- `lib/` - Compiled CMI files and JavaScript-compiled CMA files
- `findlib_index` - Index of available packages

### 3. Start the Web Server

```bash
cd _build/default/example
python3 server.py 8000
```

Or use any HTTP server with CORS support. The `server.py` script adds necessary headers.

### 4. Open the Demo

Navigate to: **http://localhost:8000/demo.html**

## File Structure

```
example/
├── demo.html          # Main demo page (feature showcase)
├── demo.js            # JavaScript client for the demo
├── worker.ml          # WebWorker entry point (1 line!)
├── server.py          # Development server with CORS
├── dune               # Build configuration
├── _opam/             # Generated: compiled packages
│   ├── worker.js      # The compiled WebWorker
│   ├── lib/           # CMI files and .cma.js files
│   └── findlib_index  # Package index
└── *.html, *.ml       # Other example files
```

## Adding More Libraries

To add additional OCaml libraries to the demo, edit the `dune` file:

```dune
(rule
 (targets
  (dir _opam))
 (action
  (run jtw opam -o _opam str stringext core YOUR_LIBRARY)))
```

Then rebuild:

```bash
dune build @example/default
```

The `jtw opam` command:
1. Finds all transitive dependencies
2. Copies CMI files for type information
3. Compiles CMA files to JavaScript with `js_of_ocaml`
4. Generates the findlib index and dynamic_cmis.json files

## How It Works

### Architecture

```
┌─────────────────┐     postMessage/JSON-RPC     ┌─────────────────┐
│   Browser Tab   │ ◄──────────────────────────► │   WebWorker     │
│   (demo.js)     │                              │   (worker.js)   │
│                 │                              │                 │
│ - UI rendering  │                              │ - OCaml toplevel│
│ - RPC client    │                              │ - Merlin engine │
│ - MIME display  │                              │ - #require      │
└─────────────────┘                              └─────────────────┘
```

### RPC Methods

| Method | Description |
|--------|-------------|
| `init` | Initialize toplevel with config |
| `setup` | Setup an environment (start toplevel) |
| `exec` | Execute a phrase |
| `exec_toplevel` | Execute a toplevel script |
| `create_env` | Create isolated environment |
| `destroy_env` | Destroy an environment |
| `list_envs` | List all environments |
| `complete_prefix` | Get autocomplete suggestions |
| `type_enclosing` | Get type at position |
| `query_errors` | Get errors/warnings for code |

### MIME Output

User code can produce rich output using the `Mime_printer` module:

```ocaml
(* SVG output *)
Mime_printer.push "image/svg" "<svg>...</svg>";;

(* HTML output *)
Mime_printer.push "text/html" "<table>...</table>";;

(* Base64-encoded image *)
Mime_printer.push ~encoding:Base64 "image/png" "iVBORw0KGgo...";;
```

The demo page renders these appropriately in the UI.

## Troubleshooting

### "Worker error" on startup

- Check browser console for details
- Ensure `_opam/worker.js` exists
- Verify the server is running with CORS headers

### "Failed to fetch" errors

- The worker loads files via HTTP; check network tab
- Ensure `lib/ocaml/` directory has CMI files
- Check `findlib_index` file exists

### Library not found with #require

- Add the library to the `jtw opam` command in dune
- Rebuild with `dune build @example/default`
- Check `_opam/lib/PACKAGE/META` exists

### Autocomplete/type info not working

- Merlin needs CMI files; ensure they're in `_opam/lib/`
- The `dynamic_cmis.json` file must be present for each library

## Development

To modify the worker libraries:

1. Edit files in `lib/` (core implementation)
2. Edit files in `lib-web/` (browser-specific code)
3. Rebuild: `dune build`
4. Refresh the browser (worker is cached, may need hard refresh)

The worker entry point is minimal:

```ocaml
(* worker.ml *)
let _ = Js_top_worker_web.Worker.run ()
```

All the complexity is in the `js_top_worker-web` library.
