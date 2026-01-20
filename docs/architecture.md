# js_top_worker Architecture

This document describes the current architecture of js_top_worker and the planned changes.

## Overview

js_top_worker is an OCaml toplevel (REPL) designed to run in a Web Worker or remote process. It enables interactive OCaml execution in browsers for:

- Jupyter-style notebooks
- Interactive documentation
- Educational tools (lecture slides, tutorials)
- Library documentation with live examples

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Browser                                  │
│  ┌──────────────────┐         ┌──────────────────────────────┐  │
│  │   Frontend       │         │      Web Worker              │  │
│  │                  │         │                              │  │
│  │  ┌────────────┐  │  RPC    │  ┌────────────────────────┐  │  │
│  │  │   Client   │◄─┼────────►│  │      Server           │  │  │
│  │  │ (Lwt/Fut)  │  │ JSON    │  │   (worker.ml)         │  │  │
│  │  └────────────┘  │         │  └──────────┬─────────────┘  │  │
│  │                  │         │             │                │  │
│  │                  │         │  ┌──────────▼─────────────┐  │  │
│  │                  │         │  │     Implementation     │  │  │
│  │                  │         │  │      (impl.ml)         │  │  │
│  │                  │         │  │  - Execute phrases     │  │  │
│  │                  │         │  │  - Type checking       │  │  │
│  │                  │         │  │  - Code completion     │  │  │
│  │                  │         │  └──────────┬─────────────┘  │  │
│  │                  │         │             │                │  │
│  │                  │         │  ┌──────────▼─────────────┐  │  │
│  │                  │         │  │   js_of_ocaml-toplevel │  │  │
│  │                  │         │  │      + Merlin          │  │  │
│  │                  │         │  └────────────────────────┘  │  │
│  └──────────────────┘         └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Package Structure

| Package | Purpose | Key Files |
|---------|---------|-----------|
| `js_top_worker` | Core toplevel implementation | `lib/impl.ml`, `lib/ocamltop.ml` |
| `js_top_worker-web` | Web Worker implementation | `lib/worker.ml`, `lib/findlibish.ml` |
| `js_top_worker-rpc` | RPC type definitions | `idl/toplevel_api.ml` |
| `js_top_worker-client` | Lwt-based client | `idl/js_top_worker_client.ml` |
| `js_top_worker-client_fut` | Fut-based client | `idl/js_top_worker_client_fut.ml` |
| `js_top_worker-unix` | Unix socket backend (testing) | - |
| `js_top_worker-bin` | CLI tools (`jtw`) | `bin/jtw.ml` |

## Current Communication Layer

### RPC Protocol

Uses [ocaml-rpc](https://github.com/mirage/ocaml-rpc) with JSON-RPC 2.0:

```
Client                              Server (Worker)
   │                                     │
   │  ──── JSON-RPC request ────────►    │
   │       {method: "exec",              │
   │        params: ["let x = 1"],       │
   │        id: 1}                       │
   │                                     │
   │  ◄─── JSON-RPC response ────────    │
   │       {result: {...},               │
   │        id: 1}                       │
   │                                     │
```

### RPC Operations

| Method | Parameters | Returns | Description |
|--------|------------|---------|-------------|
| `init` | `init_config` | `unit` | Initialize toplevel |
| `setup` | `unit` | `exec_result` | Start toplevel |
| `exec` | `string` | `exec_result` | Execute OCaml phrase |
| `typecheck` | `string` | `exec_result` | Type check without execution |
| `complete_prefix` | `id, deps, source, position` | `completions` | Autocomplete |
| `query_errors` | `id, deps, source` | `error list` | Get compilation errors |
| `type_enclosing` | `id, deps, source, position` | `typed_enclosings` | Type at position |

### Type Definitions

Key types from `idl/toplevel_api.ml`:

```ocaml
type exec_result = {
  stdout : string option;
  stderr : string option;
  sharp_ppf : string option;      (* # directive output *)
  caml_ppf : string option;       (* Regular output *)
  highlight : highlight option;   (* Error location *)
  mime_vals : mime_val list;      (* Rich output *)
}

type mime_val = {
  mime_type : string;             (* e.g., "text/html" *)
  encoding : encoding;            (* Noencoding | Base64 *)
  data : string;
}

type init_config = {
  findlib_requires : string list; (* Packages to preload *)
  stdlib_dcs : string option;     (* Dynamic CMIs URL *)
  execute : bool;                 (* Allow execution? *)
}
```

## Core Implementation

### Module Structure (`lib/impl.ml`)

```ocaml
module type S = sig
  type findlib_t
  val capture : (unit -> 'a) -> unit -> captured * 'a
  val sync_get : string -> string option
  val async_get : string -> (string, [`Msg of string]) result Lwt.t
  val import_scripts : string list -> unit
  val get_stdlib_dcs : string -> dynamic_cmis list
  val findlib_init : string -> findlib_t Lwt.t
  val require : bool -> findlib_t -> string list -> dynamic_cmis list
  val path : string
end

module Make (S : S) : sig
  val init : init_config -> unit Lwt.t
  val setup : unit -> exec_result Lwt.t
  val exec : string -> exec_result Lwt.t
  val typecheck : string -> exec_result Lwt.t
  (* ... *)
end
```

### Execution Flow

```
exec(phrase)
    │
    ▼
capture stdout/stderr
    │
    ▼
parse phrase (Ocamltop.parse_toplevel)
    │
    ▼
execute (Toploop.execute_phrase)
    │
    ▼
collect MIME outputs
    │
    ▼
return exec_result
```

### Cell Dependency System

Cells can depend on previous cells via module wrapping:

```ocaml
(* Cell "c1" defines: *)
let x = 1

(* Internally becomes module Cell__c1 *)

(* Cell "c2" with deps=["c1"]: *)
let y = x + 1

(* Prepended with: open Cell__c1 *)
```

The `mangle_toplevel` function handles this transformation.

## Library Loading

### findlibish.ml

Custom findlib-like implementation for WebWorker context:

```
                          ┌─────────────────┐
                          │  findlib_index  │ (list of META URLs)
                          └────────┬────────┘
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
              ┌─────────┐   ┌─────────┐   ┌─────────┐
              │  META   │   │  META   │   │  META   │
              │ (pkg A) │   │ (pkg B) │   │ (pkg C) │
              └────┬────┘   └────┬────┘   └────┬────┘
                   │             │             │
                   ▼             ▼             ▼
              ┌─────────────────────────────────────┐
              │        Dependency Resolution         │
              └─────────────────┬───────────────────┘
                                │
                   ┌────────────┼────────────┐
                   ▼            ▼            ▼
             ┌──────────┐ ┌──────────┐ ┌──────────┐
             │ .cma.js  │ │ .cma.js  │ │ .cma.js  │
             │ (import) │ │ (import) │ │ (import) │
             └──────────┘ └──────────┘ └──────────┘
```

### Package Loading Process

1. Fetch `findlib_index` (list of META file URLs)
2. Parse each META file with `Fl_metascanner`
3. Build dependency graph
4. On `#require`:
   - Resolve dependencies
   - Fetch `dynamic_cmis.json` for each package
   - Load `.cma.js` via `import_scripts`

### Preloaded Packages

These are compiled into the worker and not loaded dynamically:

- `compiler-libs.common`, `compiler-libs.toplevel`
- `merlin-lib.*`
- `js_of_ocaml-compiler`, `js_of_ocaml-toplevel`
- `findlib`, `findlib.top`

## Merlin Integration

Code intelligence features use Merlin:

| Feature | Merlin Query | Implementation |
|---------|--------------|----------------|
| Completion | `Query_protocol.Complete_prefix` | `complete_prefix` |
| Type info | `Query_protocol.Type_enclosing` | `type_enclosing` |
| Errors | `Query_protocol.Errors` | `query_errors` |

Queries run through `Mpipeline` with source "mangled" to include cell dependencies.

## Planned Architecture Changes

### Phase 1: Communication Redesign

Replace JSON-RPC with CBOR-based bidirectional channel:

```
Current:                           Planned:
┌─────────┐     JSON-RPC          ┌─────────┐     CBOR
│ Client  │◄──────────────►       │ Client  │◄──────────────►
│         │  request/response     │         │  bidirectional
└─────────┘                       └─────────┘

                                  Message types:
                                  - Request/Response (like RPC)
                                  - Push (server → client)
                                  - Widget events (bidirectional)
```

### Phase 2: Environment Isolation

Multiple isolated execution contexts:

```
┌──────────────────────────────────────────┐
│              Web Worker                   │
│                                          │
│  ┌─────────────┐    ┌─────────────┐     │
│  │   Env "a"   │    │   Env "b"   │     │
│  │             │    │             │     │
│  │ Cell 1      │    │ Cell 1      │     │
│  │ Cell 2      │    │ Cell 2      │     │
│  │ (isolated)  │    │ (isolated)  │     │
│  └─────────────┘    └─────────────┘     │
│                                          │
│  Shared: stdlib, preloaded packages      │
└──────────────────────────────────────────┘
```

### Phase 3: Rich Output & Widgets

MIME-typed output with bidirectional widget communication:

```ocaml
(* User code *)
let chart = Chart.bar [1; 2; 3; 4] in
Display.show chart

(* Generates *)
{
  mime_type = "application/vnd.widget+json";
  data = {widget_id = "w1"; state = ...}
}

(* Frontend renders widget, sends events back *)
Widget_event {widget_id = "w1"; event = Click {x; y}}
```

## File Reference

### Core Files

| File | Lines | Purpose |
|------|-------|---------|
| `lib/impl.ml` | 985 | Main implementation (execute, typecheck, etc.) |
| `lib/worker.ml` | 100 | WebWorker server setup |
| `lib/findlibish.ml` | 221 | Package loading |
| `idl/toplevel_api.ml` | 315 | RPC type definitions |
| `idl/js_top_worker_client.ml` | 126 | Lwt client |

### Build Outputs

| File | Description |
|------|-------------|
| `worker.bc.js` | Compiled Web Worker |
| `*.cma.js` | JavaScript-compiled OCaml libraries |
| `dynamic_cmis.json` | CMI metadata for each package |

## Dependencies

### Runtime

- `js_of_ocaml` >= 3.11.0
- `js_of_ocaml-toplevel`
- `js_of_ocaml-compiler`
- `rpclib`, `rpclib-lwt`
- `merlin-lib`
- `compiler-libs`
- `brr` >= 0.0.4

### Planned Additions

- `cbort` - CBOR codec (tangled.org)
- `zarith_stubs_js` - JS stubs for zarith
- `bytesrw` - Streaming I/O

---

*Last updated: 2026-01-20*
