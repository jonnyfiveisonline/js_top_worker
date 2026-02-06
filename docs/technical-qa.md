# Technical Q&A Log

This file records technical questions and answers about the codebase, along with verification steps taken to ensure accuracy.

---

## 2026-02-06: Is js_of_ocaml compilation deterministic?

**Question**: Is js_of_ocaml compilation deterministic? If we rebuild the same package, will the `.cma.js` file have the same content hash? This matters for using content hashes as cache-busting URLs.

**Answer**: Yes, js_of_ocaml compilation is deterministic. Given the same inputs (bytecode, debug info, compiler version, flags), it produces byte-for-byte identical JavaScript output. This is confirmed by both the js_of_ocaml maintainer (hhugo) and empirical testing.

**Evidence**:

1. **Maintainer confirmation** (GitHub issue ocsigen/js_of_ocaml#1297): hhugo (Hugo Heuzard, core maintainer) stated: "Js_of_ocaml produces JS from ocaml bytecode and uses debug info (from the bytecode) to recover variable names. The renaming algo is deterministic. You should expect the jsoo build to be reproducible."

2. **Source code analysis**: The `js_output.ml` file in the compiler converts internal Hashtbl structures to sorted lists before output generation:
   ```ocaml
   let hashtbl_to_list htb =
     String.Hashtbl.fold (fun k v l -> (k, v) :: l) htb []
     |> List.sort ~cmp:(fun (_, a) (_, b) -> compare a b)
     |> List.map ~f:fst
   ```
   This ensures deterministic output regardless of Hashtbl iteration order.

3. **No embedded non-deterministic data**: Grep of `.cma.js` files found no embedded timestamps, build paths, random values, or other non-deterministic content.

4. **Empirical testing** (OCaml 5.4.0, js_of_ocaml 6.2.0): Four consecutive `dune clean && dune build` cycles (including one with `-j 1`) produced byte-for-byte identical `.cma.js` files:
   - `stdlib.cma.js`: `496346f4...` (all 4 builds)
   - `lwt.cma.js`: `e65a4a54...` (all 4 builds)
   - `rpclib.cma.js`: `ffaa5ffc...` (all 4 builds)
   - `js_of_ocaml.cma.js`: `4169ea91...` (all 4 builds)

**Caveats**:

- **Different OCaml compiler versions** will produce different bytecode, which leads to different `.cma.js` output. Content hashes are stable only when the full toolchain is pinned.
- **Different js_of_ocaml versions** or different compiler flags (e.g., `--opt 3` vs default) will produce different output.
- **Dune parallel build bug** (dune#3863): On OCaml < 4.11, parallel builds could produce non-deterministic `.cmo` files due to debug info sensitivity. This is fixed in OCaml 4.11+ (we use 5.4.0).
- **`dune-build-info`**: If a package uses `dune-build-info`, the VCS revision can be embedded in the binary, but this does not affect `.cma.js` compilation for libraries that don't use it.

**Conclusion**: Content hashes of `.cma.js` files are safe to use for cache-busting URLs, provided the OCaml toolchain version and js_of_ocaml version are held constant (which they are within a single ohc layer build).

**Verification Steps**:
- Searched web for "js_of_ocaml deterministic", "js_of_ocaml reproducible build"
- Read GitHub issue ocsigen/js_of_ocaml#1297 and all comments
- Analyzed js_of_ocaml compiler source (`generate.ml`, `js_output.ml`) for non-determinism
- Performed 4 clean rebuilds and compared SHA-256 hashes
- Tested both default parallelism and `-j 1` single-core builds
- Grepped `.cma.js` output for embedded paths, timestamps, dates

---

## 2026-01-20: What does `--include-runtime` do in js_of_ocaml?

**Question**: What does the `--include-runtime` argument actually do when compiling with js_of_ocaml?

**Answer**: The `--include-runtime` flag embeds library-specific JS stubs (from the library's `runtime.js` files) into the compiled output. It does NOT include the full js_of_ocaml runtime.

When used with `--toplevel`, it:
1. Takes the library's `runtime.js` stubs (e.g., `+base/runtime.js`)
2. Embeds them in the compiled `.js` file
3. Registers them on `jsoo_runtime` via `Object.assign()`

This allows separate compilation where each library's `.cma.js` file carries its own stubs, rather than requiring all stubs to be bundled into the main toplevel.

**Verification Steps**:

1. **File size comparison**: Compiled `base.cma.js` with and without `--include-runtime`
   - With: 629KB
   - Without: 626KB
   - Difference: ~3KB (just the stubs, not the full runtime)

2. **Searched for runtime functions**:
   ```bash
   grep -c "function caml_call_gen" base.cma.js
   # Result: 0 definitions, 215 references

   grep -c "function caml_register_global" base.cma.js
   # Result: 0 definitions, 146 references
   ```
   This confirms the core runtime is NOT included.

3. **Found stub registration pattern**:
   ```javascript
   Object.assign(a.jsoo_runtime, {Base_am_testing: m, Base_hash_stubs: n, ...})
   ```
   This shows how stubs are registered on the global `jsoo_runtime` object.

4. **Runtime test**: The Node.js test in `test/node/` successfully loads `base` and uses functions that depend on JS stubs (hash functions), confirming the stubs work correctly when embedded this way.

**Related**: js_of_ocaml PR #1509 added support for this feature in toplevel mode.

---
