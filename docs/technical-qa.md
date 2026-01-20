# Technical Q&A Log

This file records technical questions and answers about the codebase, along with verification steps taken to ensure accuracy.

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
