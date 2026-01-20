# js_top_worker Investigation Report

This document captures research findings for the communication layer redesign.

## Phase 0.1: Wire Format Research

### Goal

Find a suitable serialization format for bidirectional typed messaging between frontend (browser) and backend (WebWorker/remote).

### Requirements

- Binary format preferred (compact, fast)
- Type-safe OCaml codec (define once, use for both encode/decode)
- js_of_ocaml compatible
- Support for structured data (records, variants, arrays, maps)

### Options Evaluated

| Library | Format | js_of_ocaml | Notes |
|---------|--------|-------------|-------|
| ocaml-rpc (current) | JSON-RPC | Yes | Request-response only, no push |
| jsont | JSON | Yes (via brr) | Type-safe combinators, JSON only |
| msgpck | MessagePack | Likely (pure OCaml) | Less active |
| cbor | CBOR | Likely (pure OCaml) | Basic API |
| **cbort** | CBOR | Yes (via zarith_stubs_js) | Type-safe combinators, RFC 8949 |

### Recommendation: cbort

The [cbort](https://tangled.org/@anil.recoil.org/ocaml-cbort.git) library by Anil Madhavapeddy is the best choice:

1. **Type-safe combinators** following the jsont pattern - define codecs once, use bidirectionally
2. **CBOR format** (RFC 8949) - compact binary, smaller than JSON, widely supported
3. **js_of_ocaml compatible** via zarith_stubs_js for arbitrary-precision integers
4. **Built on bytesrw** for efficient streaming I/O
5. **Path-aware error messages** for debugging decode failures

#### Example Codec Definition

```ocaml
open Cbort

type person = { name : string; age : int }

let person_codec =
  let open Obj in
  let* name = mem "name" (fun p -> p.name) string in
  let* age = mem "age" (fun p -> p.age) int in
  return { name; age }
  |> finish

(* Encode to CBOR bytes *)
let encoded = encode_string person_codec { name = "Alice"; age = 30 }

(* Decode from CBOR bytes *)
let decoded = decode_string person_codec encoded
```

#### Dependencies

- `bytesrw >= 0.2` - Pure OCaml streaming I/O
- `zarith >= 1.12` - Arbitrary precision integers (uses zarith_stubs_js for JS)
- `crowbar` - Fuzz testing (dev only)

#### Installation

Currently available from tangled.org:
```
git clone https://tangled.org/@anil.recoil.org/ocaml-cbort.git
```

Will need pin-depends in dune-project until published to opam.

### Jupyter Protocol Reference

For comparison, Jupyter uses:
- **JSON** for message content
- **ZeroMQ** for transport (multipart messages)
- **MIME types** for rich output (text/plain, text/html, image/png, etc.)

Key Jupyter message types:
- `execute_request` / `execute_reply` - Code execution
- `stream` - stdout/stderr output
- `display_data` - MIME-typed rich output
- `comm_open` / `comm_msg` - Bidirectional widget communication

Our design will follow similar patterns but use CBOR instead of JSON.

---

## Phase 0.2: Findlib Investigation

### Goal

Understand what real `findlib.top` does and whether to integrate it or improve `findlibish`.

### Current Implementation: findlibish

The project has a custom `findlibish.ml` (221 lines) that:

1. Parses META files using `Fl_metascanner`
2. Builds a library dependency graph
3. Resolves `#require` requests
4. Loads `.cma.js` archives via `import_scripts`
5. Fetches `dynamic_cmis.json` for type information

Key differences from real findlib:
- No `topfind` file mechanism
- No `#list`, `#camlp4o`, etc. directives
- Hardcoded list of "preloaded" packages (compiler-libs, merlin, etc.)
- URL-based fetching instead of filesystem access

### Real Findlib Behavior (from source analysis)

Studied [ocamlfind source](https://github.com/ocaml/ocamlfind) - specifically `src/findlib/topfind.ml.in`.

#### Directive Registration

Findlib registers directives by adding to `Toploop.directive_table`:

```ocaml
Hashtbl.add
  Toploop.directive_table
  "require"
  (Toploop.Directive_string
     (fun s -> protect load_deeply (Fl_split.in_words s)))
```

#### Package Loading (`load` function)

The `load` function performs these steps:
1. Get package directory via `Findlib.package_directory pkg`
2. Add directory to search path via `Topdirs.dir_directory d`
3. Get `archive` property from META file
4. Load archives via `Topdirs.dir_load Format.std_formatter archive`
5. Handle PPX properties (if defined)
6. Record package as loaded via `Findlib.record_package`

#### Deep Loading (`load_deeply` function)

```ocaml
let load_deeply pkglist =
  (* Get the sorted list of ancestors *)
  let eff_pkglist =
    Findlib.package_deep_ancestors !predicates pkglist in
  (* Check for error properties *)
  List.iter (fun pkg ->
    try let error = Findlib.package_property !predicates pkg "error" in
      failwith ("Error from package `" ^ pkg ^ "': " ^ error)
    with Not_found -> ()) eff_pkglist ;
  (* Load the packages in turn: *)
  load eff_pkglist
```

#### Key Mechanisms

| Findlib | findlibish | Notes |
|---------|------------|-------|
| `Topdirs.dir_load` | `import_scripts` | Native .cma vs .cma.js |
| `Topdirs.dir_directory` | N/A | Search path management |
| `Findlib.package_directory` | URL-based | Filesystem vs HTTP |
| Predicate system | Hardcoded | `["byte"; "toploop"]` etc. |
| `Findlib.record_package` | `loaded` mutable field | Track loaded packages |

### Recommendation

**Keep findlibish but improve it**. The architectures are fundamentally different:

1. **Findlib**: Native bytecode loading, filesystem access, Toploop integration
2. **findlibish**: JavaScript module loading, URL fetching, WebWorker context

Key improvements to make:
1. Add `.mli` file documenting the API
2. Support `#list` directive for discoverability
3. Better error messages when packages not found
4. Add test to verify `preloaded` list matches build (see below)
5. Add predicate support for conditional archives

#### Preloaded List Synchronization

The `preloaded` list in `findlibish.ml` must match packages linked into the
worker via dune. Currently this is manually maintained and can drift.

**Solution**: Add a test that verifies consistency:
- Query actually-linked packages (via `Findlib.recorded_packages()` or similar)
- Compare against `preloaded` list
- Fail with clear message if they differ

This catches drift without adding build-time complexity. The current list also
has duplicates (`js_of_ocaml-ppx`, `findlib`) that should be cleaned up.

---

## Phase 0.3: Environment Model Research

### Goal

Understand how to support multiple isolated execution environments (like mdx `x-ocaml` blocks).

### Current State

The project already has cell ID support:
- `opt_id` parameter on API calls
- `Cell__<id>` modules for cell outputs
- `failed_cells` tracking for dependency management
- `mangle_toplevel` adds `open Cell__<dep>` for dependencies

### MDX Implementation (from source analysis)

Studied [mdx source](https://github.com/realworldocaml/mdx) - specifically `lib/top/mdx_top.ml`.

MDX implements environment isolation by capturing and restoring Toploop state:

```ocaml
(* Environment storage: name -> (type_env, binding_names, runtime_values) *)
let envs = Hashtbl.create 8

(* Extract user-defined bindings from environment summary *)
let env_deps env =
  let names = save_summary [] (Env.summary env) in
  let objs = List.map Toploop.getvalue names in
  (env, names, objs)

(* Restore environment state *)
let load_env env names objs =
  Toploop.toplevel_env := env;
  List.iter2 Toploop.setvalue names objs

(* Execute code in a named environment *)
let in_env e f =
  let env_name = Mdx.Ocaml_env.name e in
  let env, names, objs =
    try Hashtbl.find envs env_name
    with Not_found -> env_deps !default_env
  in
  load_env env names objs;
  let res = f () in
  (* Save updated state *)
  Hashtbl.replace envs env_name (env_deps !Toploop.toplevel_env);
  res
```

#### Key Toploop State Components

| Component | Access Method | Description |
|-----------|---------------|-------------|
| Type environment | `Toploop.toplevel_env` | Type bindings, modules |
| Runtime values | `Toploop.getvalue`/`setvalue` | Actual OCaml values |
| Environment summary | `Env.summary` | List of binding operations |

#### MDX's Strategy

1. **Shared base**: All environments start from `default_env` (initial Toploop state)
2. **Capture on exit**: After execution, save `(env, names, objs)` tuple
3. **Restore on entry**: Before execution, restore the saved state
4. **Hashtable storage**: Environments keyed by string name

### Implications for js_top_worker

The MDX approach works because it runs in a native OCaml process with mutable global state. For WebWorker:

1. **Same approach possible**: We have Toploop in js_of_ocaml-toplevel
2. **Memory concern**: Each environment stores captured values - could grow large
3. **No true fork**: Can't fork WebWorker, must use save/restore pattern
4. **Cell IDs vs Environments**: Current cell system is different - cells can depend on each other, environments are isolated

### x-ocaml Implementation (better than mdx)

Studied [x-ocaml](https://github.com/art-w/x-ocaml) by @art-w - cleaner approach.

#### Value Capture with Env.diff

```ocaml
module Value_env = struct
  type t = Obj.t String_map.t

  let capture t idents =
    List.fold_left (fun t ident ->
      let name = Translmod.toplevel_name ident in
      let v = Topeval.getvalue name in
      String_map.add name v t
    ) t idents

  let restore t =
    String_map.iter (fun name v -> Topeval.setvalue name v) t
end
```

Key insight: Uses `Env.diff previous_env current_env` to get only NEW bindings,
rather than walking the full environment summary like mdx does.

#### Stack-based Environment Management

```ocaml
module Environment = struct
  let environments = ref []  (* stack of (id, typing_env, value_env) *)

  let reset id =
    (* Walk stack until we find id, restore that state *)
    environments := go id !environments

  let capture id =
    let idents = Env.diff previous_env !Toploop.toplevel_env in
    let values = Value_env.capture previous_values idents in
    environments := (id, !Toploop.toplevel_env, values) :: !environments
end
```

Benefits:
- Can backtrack to any previous checkpoint
- Only captures incremental changes (memory efficient)
- Simple integer IDs

#### PPX Integration

```ocaml
(* Capture all registered PPX rewriters *)
let ppx_rewriters = ref []

let () =
  Ast_mapper.register_function :=
    fun _ f -> ppx_rewriters := f :: !ppx_rewriters

(* Apply during phrase preprocessing *)
let preprocess_phrase phrase =
  match phrase with
  | Ptop_def str -> Ptop_def (preprocess_structure str)
  | Ptop_dir _ as x -> x
```

ppxlib bridge (`ppxlib_register.ml`):
```ocaml
let () = Ast_mapper.register "ppxlib" mapper
```

### Recommended Design

Adopt x-ocaml's core patterns, adapted for js_top_worker's purpose as a
reusable backend library:

**From x-ocaml (adopt directly)**:
1. **Incremental capture** via `Env.diff` - replaces current cell wrapping
2. **PPX via `Ast_mapper.register_function`** override
3. **ppxlib bridge** for modern PPX ecosystem

**Adapted for js_top_worker**:
1. **Named environments** instead of pure stack (multiple notebooks can coexist)
2. **MIME output API** generalizing x-ocaml's `output_html`
3. **cbort protocol** instead of Marshal (type-safe, browser-friendly)

**API sketch**:
```ocaml
type env_id = string

(* Environment management *)
val create_env : ?base:env_id -> env_id -> unit
val checkpoint : env_id -> unit  (* capture current state *)
val reset : env_id -> unit       (* restore to last checkpoint *)
val destroy_env : env_id -> unit

(* Execution *)
val exec : env:env_id -> string -> exec_result

(* MIME output (callable from user code) *)
val display : ?mime_type:string -> string -> unit
```

This gives us x-ocaml's simplicity while supporting:
- Multiple concurrent environments (different notebooks)
- Checkpoint/reset within an environment (cell re-execution)
- Rich output beyond just HTML

---

## Phase 0.4: Existing Art Review

### Projects Analyzed

| Project | URL | Architecture |
|---------|-----|--------------|
| ocaml-jupyter | https://github.com/akabe/ocaml-jupyter | Native OCaml + ZeroMQ |
| js_of_ocaml toplevel | https://ocsigen.org/js_of_ocaml | Browser + js_of_ocaml |
| sketch.sh | https://github.com/Sketch-sh/sketch-sh | Browser + WebWorker |
| utop | https://github.com/ocaml-community/utop | Native OCaml + terminal |

### ocaml-jupyter

**Architecture**: Native OCaml kernel communicating via ZeroMQ (Jupyter protocol v5.2).

**Key components**:
- `jupyter` - Core protocol implementation
- `jupyter.notebook` - Rich output API (HTML, markdown, images, LaTeX)
- `jupyter.comm` - Bidirectional widget communication

**Rich output**: Programmatic generation via `jupyter.notebook` library:
```ocaml
(* Example from jupyter.notebook *)
Jupyter_notebook.display "text/html" "<b>Hello</b>"
```

**Code completion**: Merlin integration, reads `.merlin` files.

**Takeaway**: Good reference for MIME output API and comm protocol design.

### js_of_ocaml Toplevel

**Architecture**: OCaml bytecode compiled to JavaScript, runs in browser.

**Build flags**:
```bash
js_of_ocaml --toplevel --linkall +weak.js +toplevel.js +dynlink.js
```

**Library loading**: Two approaches:
1. Compile libraries into toplevel directly
2. Load dynamically via `--extern-fs` pseudo-filesystem

**Takeaway**: Foundation of our project. We already use js_of_ocaml-toplevel.

### Sketch.sh

**Architecture**: Browser-based notebook using js_of_ocaml toplevel in WebWorker.

**Key insight**: "rtop-evaluator loads refmt & js_of_ocaml compiler as a web worker"

**Features**:
- Multiple OCaml versions (4.06.1, 4.13.1, 5.3.0)
- Reason syntax support via refmt
- Notebook-style cells with inline evaluation
- OCaml 5 effects support (continuation-based in JS)

**Limitations**:
- No BuckleScript modules (Js module)
- Belt library support added later

**Takeaway**: Similar architecture to js_top_worker. Good reference for multi-version support.

### utop

**Architecture**: Enhanced native OCaml toplevel with:
- Line editing (lambda-term)
- History
- Context-sensitive completion
- Colors

**Features relevant to us**:
- `UTop.set_create_implicits` - Auto-generate module interfaces
- Merlin integration for completion
- PPX rewriter support

**Takeaway**: Reference for toplevel UX features (completion, error formatting).

### Comparison Summary

| Feature | ocaml-jupyter | sketch.sh | js_top_worker |
|---------|---------------|-----------|---------------|
| Runtime | Native | Browser/Worker | Browser/Worker |
| Protocol | Jupyter/ZMQ | Custom | RPC (current) |
| Rich output | MIME via API | Limited | MIME (planned) |
| Widgets | jupyter.comm | No | Planned |
| Multi-env | No | No | Planned |
| Completion | Merlin | Basic | Merlin |

### Key Lessons

1. **MIME output**: jupyter.notebook provides good API pattern
2. **Widget comm**: jupyter.comm shows bidirectional messaging
3. **WebWorker**: sketch.sh validates our architecture choice
4. **Environment isolation**: None of these support it - opportunity for differentiation

---

## Open Questions

1. **Widget state persistence**: How long should widget state live? Per-session? Per-environment?

2. **Streaming output**: Should stdout/stderr be pushed incrementally or batched?

3. **PPX scope**: When a PPX is installed, should it apply to:
   - All environments?
   - Just the current environment?
   - Configurable?

4. **Error recovery**: If a cell fails, how do dependent cells behave?
   - Current: tracked in `failed_cells` set
   - Desired: TBD

---

## Summary of Findings

### Wire Format Decision: cbort

Use [cbort](https://tangled.org/@anil.recoil.org/ocaml-cbort.git) for CBOR-based typed messaging:
- Type-safe combinators (jsont-style)
- Binary format (compact, fast)
- js_of_ocaml compatible via zarith_stubs_js

### Findlib Decision: Keep findlibish

The current `findlibish.ml` is appropriate for WebWorker context:
- URL-based package loading (not filesystem)
- JavaScript module loading via `import_scripts`
- Add `.mli` file and improve error handling
- Add test to verify preloaded list matches build

### Environment Model Decision: x-ocaml-style capture/restore

Adopt [x-ocaml](https://github.com/art-w/x-ocaml)'s approach:
- **`Env.diff`** for incremental capture (only new bindings)
- **`Topeval.getvalue`/`setvalue`** for runtime values
- **Named environments** (adapting x-ocaml's integer stack)
- **PPX via `Ast_mapper.register_function`** override

This replaces the current cell module wrapping approach with something simpler
and more powerful (supports checkpoint/reset, not just forward execution).

### Key Differentiators

Features that set js_top_worker apart:
1. **Multiple named environments** - Not supported by competitors
2. **CBOR wire format** - More efficient than JSON/Marshal
3. **Bidirectional widgets** - Like Jupyter but in browser
4. **PPX support** - Via x-ocaml's pattern + ppxlib bridge
5. **Reusable backend** - Library for others to build on

---

## Next Steps

### Immediate (Phase 1)

1. **Add cbort dependency**: Pin-depends in dune-project
2. **Define message types**: Simple ADT like x-ocaml, encoded with cbort
   ```ocaml
   type request =
     | Setup
     | Eval of { env : string; code : string }
     | Merlin of { env : string; action : Merlin_protocol.action }
     | Checkpoint of { env : string }
     | Reset of { env : string }

   type response =
     | Setup_complete
     | Output of { env : string; loc : int; data : output list }
     | Eval_complete of { env : string; result : exec_result }
     | Merlin_response of Merlin_protocol.answer
   ```
3. **Replace RPC with simple message handling**: Like x-ocaml's pattern match
4. ~~**Remove compile_js**: Delete unused method~~ ✓ Done

### Short-term (Phase 2)

5. **Environment isolation**: x-ocaml's `Env.diff` + `Topeval.getvalue/setvalue`
6. **PPX support**: `Ast_mapper.register_function` override + ppxlib bridge
7. **Add .mli files**: `impl.mli`, `findlibish.mli`
8. **CI setup**: GitHub Actions for OCaml 5.2+
9. **Preloaded list test**: Verify sync with build

### Medium-term (Phase 3)

10. **MIME output API**: Generalize x-ocaml's `output_html` pattern
11. **Widget protocol**: Bidirectional comm for interactive widgets
12. **OCamlformat integration**: Auto-format like x-ocaml

---

*Last updated: 2026-01-20*
