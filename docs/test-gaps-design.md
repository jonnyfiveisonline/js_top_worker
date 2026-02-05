# Test Gap Analysis and Design

## Current State

### Existing Infrastructure

| Type | Location | Framework | Status |
|------|----------|-----------|--------|
| Node.js tests | `test/node/` | OCaml → js_of_ocaml → Node.js | ✅ Integrated in dune |
| Cram tests | `test/cram/` | Shell + unix_worker/client | ✅ Integrated in dune |
| Unit tests | `test/libtest/` | ppx_expect | ✅ Integrated in dune |
| Browser tests | `test/browser/` | Playwright | ❌ **Not integrated** |

### Browser Test Files (exist but not wired up)

```
test/browser/
├── package.json          # Playwright dependency
├── run_tests.js          # Playwright runner (serves files, runs browser)
├── test.html             # Test harness HTML
├── client_test.ml        # OCaml test code (needs compilation)
├── test_worker.ml        # Test worker (needs compilation)
├── test_features.js      # Feature tests (MIME, autocomplete, etc.)
├── test_env_isolation.js # Environment isolation test
└── test_demo.js          # Demo page test
```

## Critical Gaps

### 1. Cell Dependencies

**Current coverage:** Linear chain only (`c1 → c2 → c3 → c4`)

**Missing scenarios:**

```
A. Diamond dependency:
   c1 (type t = int)
     ↓         ↓
   c2 (x:t)   c3 (y:t)
         ↓   ↓
         c4 (x + y)

B. Missing dependency:
   c2 depends on ["c1"] but c1 doesn't exist → should error gracefully

C. Circular reference handling:
   c1 depends on ["c2"], c2 depends on ["c1"] → should detect/reject

D. Dependency update propagation:
   c1 changes → c2, c3 that depend on c1 should see new types

E. Type shadowing across cells:
   c1: type t = int
   c2: type t = string  (depends on c1)
   c3: uses t (depends on c1, c2) → which t?
```

### 2. Error Recovery

**Missing scenarios:**

```
A. Syntax errors:
   - Unterminated string/comment
   - Mismatched brackets
   - Invalid tokens

B. Type errors with recovery:
   - First phrase errors, second should still work
   - Error in middle of multi-phrase input

C. Runtime errors:
   - Stack overflow (deep recursion)
   - Out of memory (large data structures)
   - Division by zero

D. Toplevel state corruption:
   - Can we continue after an error?
   - Is state consistent after partial execution?
```

### 3. Browser/WebWorker Integration

**Problem:** Tests exist but aren't run by `dune runtest`

**Current workflow (manual):**
```bash
cd test/browser
npm install
# Manually build OCaml files somehow
npm test
```

**Needed workflow:**
```bash
dune runtest  # Should include browser tests
```

## Proposed Design

### Browser Test Integration

#### Option A: Playwright in dune (Recommended)

```
test/browser/dune:
─────────────────────
(executable
 (name client_test)
 (modes js)
 (libraries js_top_worker-client lwt js_of_ocaml))

(executable
 (name test_worker)
 (modes js)
 (libraries js_top_worker-web ...))

(rule
 (alias runtest)
 (deps
   client_test.bc.js
   test_worker.bc.js
   test.html
   (:runner run_tests.js))
 (action
  (run node %{runner})))
```

**Pros:**
- Integrated into normal `dune runtest`
- OCaml files compiled automatically
- Playwright handles browser lifecycle

**Cons:**
- Requires Node.js + Playwright installed
- Slower than headless Node tests

#### Option B: Separate browser test target

```bash
dune runtest           # Node + cram tests only
dune runtest @browser  # Browser tests (when Playwright available)
```

**Pros:**
- CI can skip browser tests if Playwright not available
- Faster default test runs

**Cons:**
- Easy to forget to run browser tests

#### Recommendation: Option B with CI integration

- Default `dune runtest` excludes browser tests
- `dune runtest @browser` for browser tests
- CI runs both

### Cell Dependency Tests

Add to `test/node/node_dependency_test.ml`:

```ocaml
(* Test diamond dependencies *)
let test_diamond rpc =
  (* c1: base type *)
  let* _ = query_errors rpc "" (Some "c1") [] false "type point = {x:int; y:int};;" in

  (* c2, c3: both depend on c1 *)
  let* _ = query_errors rpc "" (Some "c2") ["c1"] false "let origin : point = {x=0;y=0};;" in
  let* _ = query_errors rpc "" (Some "c3") ["c1"] false "let unit_x : point = {x=1;y=0};;" in

  (* c4: depends on c2 and c3 *)
  let* errors = query_errors rpc "" (Some "c4") ["c2";"c3"] false
    "let add p1 p2 = {x=p1.x+p2.x; y=p1.y+p2.y};; add origin unit_x;;" in

  assert (List.length errors = 0);
  Lwt.return (Ok ())

(* Test missing dependency *)
let test_missing_dep rpc =
  let* errors = query_errors rpc "" (Some "c2") ["nonexistent"] false "let x = 1;;" in
  (* Should either error or work without the dep *)
  ...

(* Test dependency update *)
let test_dep_update rpc =
  let* _ = query_errors rpc "" (Some "c1") [] false "type t = int;;" in
  let* _ = query_errors rpc "" (Some "c2") ["c1"] false "let x : t = 42;;" in

  (* Update c1 *)
  let* _ = query_errors rpc "" (Some "c1") [] false "type t = string;;" in

  (* c2 should now have error (42 is not string) *)
  let* errors = query_errors rpc "" (Some "c2") ["c1"] false "let x : t = 42;;" in
  assert (List.length errors > 0);
  Lwt.return (Ok ())
```

### Error Recovery Tests

Add to `test/node/node_error_test.ml`:

```ocaml
(* Test recovery after syntax error *)
let test_syntax_recovery rpc =
  (* First phrase has error *)
  let* _ = exec rpc "" "let x = ;;" in  (* syntax error *)

  (* Second phrase should still work *)
  let* result = exec rpc "" "let y = 42;;" in
  assert (result.caml_ppf |> Option.is_some);
  Lwt.return (Ok ())

(* Test partial execution *)
let test_partial_exec rpc =
  (* Multi-phrase where second fails *)
  let* result = exec rpc "" "let a = 1;; let b : string = a;; let c = 3;;" in
  (* a should be defined, b should error, c may or may not run *)
  ...
```

### Findlib Tests

Add more packages to cram tests:

```
test/cram/findlib.t/run.t:
──────────────────────────
# Test loading multiple packages with dependencies
$ unix_client exec_toplevel '' '#require "lwt";; #require "lwt.unix";;'
$ unix_client exec_toplevel '' 'Lwt_main.run (Lwt.return 42);;'

# Test package with PPX
$ unix_client exec_toplevel '' '#require "ppx_deriving.show";;'
$ unix_client exec_toplevel '' 'type t = A | B [@@deriving show];; show_t A;;'

# Test package not found
$ unix_client exec_toplevel '' '#require "nonexistent_package_12345";;'
```

## Implementation Plan

### Phase 1: Browser Test Integration ✅ COMPLETED

1. ✅ Added `test/browser/dune` to compile OCaml test files
2. ✅ Added `@browser` and `@runbrowser` aliases for Playwright tests
3. ✅ Fixed test_worker.ml to include `js_of_ocaml-toplevel` library
4. ✅ All browser tests pass (6/6)

**Key fix:** The test worker needed `js_of_ocaml-toplevel` in libraries to properly
initialize the OCaml toplevel for code compilation.

### Phase 2: Cell Dependency Tests ✅ COMPLETED

1. ✅ Created `test/node/node_dependency_test.ml`
2. ✅ Added tests for:
   - Linear dependencies (c1 → c2 → c3 → c4)
   - Diamond dependencies (d1 → d2,d3 → d4)
   - Missing dependencies (errors properly when referencing non-existent cells)
   - Dependency update propagation (type changes in d1 affect d2)
   - Type shadowing across cells
   - Complex dependency graphs with modules
3. ✅ Added to dune build with expected output

**Key finding:** Dependencies are NOT transitive. If cell d4 needs types from d1
through d2/d3, it must explicitly list d1 in its dependency array.

All 26 dependency tests pass.

### Phase 3: Error Recovery Tests (pending)

1. Create `test/node/node_error_test.ml`
2. Test syntax errors, type errors, runtime errors
3. Test state consistency after errors

### Phase 4: Expanded Findlib Tests (pending)

1. Add `test/cram/findlib.t/`
2. Test more packages (lwt, ppx_deriving, etc.)
3. Test error cases

## Decisions

1. **Browser test alias:** Separate `@browser` alias (not in default `runtest`)

2. **Browsers:** Chrome only for now

3. **Cell dependency semantics:**
   - Circular deps → Error (unbound module)
   - Missing deps → Error (unbound module)
   - Dependencies are explicit, not transitive

4. **Error recovery:** TBD - needs investigation

5. **CI:** Browser tests advisory-only initially
