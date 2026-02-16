# Widget Support Plan of Record

*Created: 2026-02-12*

## Goals

Add Jupyter-style interactive widget support to js_top_worker, enabling OCaml
code running in the toplevel to create interactive UI elements (sliders, buttons,
dropdowns, etc.) that communicate bidirectionally with the frontend.

## Design Principles

1. **Zero new dependencies in the worker** - Every dependency compiled into the
   worker can conflict with libraries the user wants to load at runtime. Widget
   support must not add any new OCaml dependencies to the worker.

2. **Broad OCaml version compatibility** - The project currently targets OCaml
   >= 4.04. New features must not raise this floor unnecessarily.

3. **Build on the message protocol, not RPC** - The worker already uses the
   message-based protocol (`message.ml` / `js_top_worker_client_msg.ml`). Widget
   communication extends this protocol rather than the legacy JSON-RPC layer.

4. **Remove, don't accumulate** - The legacy rpclib-based communication layer
   should be removed as part of this work, reducing the dependency footprint.

## Why Not CBOR?

The architecture document previously listed CBOR as a planned transport format.
After investigation, we've decided against it:

- **Dependency risk**: Even the lightweight `cbor` opam package brings in
  `ocplib-endian`. Any dependency in the worker namespace can conflict with
  user-loaded libraries.
- **Unnecessary complexity**: The existing message protocol uses `Js_of_ocaml`'s
  native JSON handling (`Json.output` / `Json.unsafe_input`), which has zero
  additional dependencies.
- **Binary data via Typed Arrays**: For binary payloads (images, etc.),
  `js_of_ocaml`'s `Typed_array` module provides native browser typed array
  support without any extra libraries.
- **JSON is the browser's native format** - No encoding/decoding overhead when
  passing structured data via `postMessage`.

## Communication Architecture

### Current State (Two Parallel Layers)

```
1. Legacy RPC (to be removed):
   Client (js_top_worker_client.ml) <-> JSON-RPC <-> Server (Toplevel_api_gen)
   Dependencies: rpclib, rpclib-lwt, rpclib.json, ppx_deriving_rpc

2. Message protocol (to be extended):
   Client (js_top_worker_client_msg.ml) <-> JSON messages <-> Worker (worker.ml)
   Dependencies: js_of_ocaml (already required)
```

### Target State

```
Client (js_top_worker_client_msg.ml)  <->  JSON messages  <->  Worker (worker.ml)
  |                                                                |
  |-- Request/Response (existing: eval, complete, errors, ...)     |
  |-- Push messages (existing: output_at streaming)                |
  |-- Widget messages (NEW: comm_open, comm_update, comm_msg, ...) |
```

All communication uses the existing `message.ml` protocol extended with widget
message types. No new serialization libraries.

## Widget Protocol Design

### Message Types (Worker -> Client)

```
CommOpen   { comm_id; target; state }    -- Widget created by OCaml code
CommUpdate { comm_id; state }            -- Widget state changed
CommClose  { comm_id }                   -- Widget destroyed
```

### Message Types (Client -> Worker)

```
CommMsg    { comm_id; data }             -- Frontend event (click, value change)
CommClose  { comm_id }                   -- Frontend closed widget
```

### Widget State Format

Widget state is a JSON object with well-known keys, following the Jupyter widget
convention where practical:

```json
{
  "widget_type": "slider",
  "value": 50,
  "min": 0,
  "max": 100,
  "step": 1,
  "description": "Threshold",
  "disabled": false
}
```

The `widget_type` field replaces Jupyter's `_model_module` / `_model_name` /
`_view_module` / `_view_name` quartet, since we don't need the npm module
indirection - our widget renderers are built into the client.

### Alignment with Jupyter Protocol

We adopt the **concepts** from the Jupyter widget protocol but simplify the
implementation:

| Jupyter Concept | Our Equivalent |
|-----------------|----------------|
| comm_open | CommOpen message |
| comm_msg method:"update" | CommUpdate message |
| comm_msg method:"custom" | CommMsg message |
| comm_close | CommClose message |
| _model_module + _model_name | widget_type string |
| buffer_paths (binary) | Typed_array via js_of_ocaml |
| Display message | CommOpen includes display flag |

We do **not** implement:
- echo_update (single frontend, no multi-client sync needed)
- request_state / request_states (state is authoritative in worker)
- Version negotiation (internal protocol, not cross-system)

## OCaml Widget API

User-facing API available as an OCaml library in the toplevel:

```ocaml
module Widget : sig
  type t

  (** Create a widget. Returns it and displays it. *)
  val slider : ?min:int -> ?max:int -> ?step:int ->
    ?description:string -> int -> t

  val button : ?style:string -> string -> t

  val text : ?placeholder:string -> ?description:string -> string -> t

  val dropdown : ?description:string -> options:string list -> string -> t

  val checkbox : ?description:string -> bool -> t

  val html : string -> t

  (** Read current value *)
  val get : t -> Yojson.Safe.t    (* or a simpler JSON type *)

  (** Update widget state *)
  val set : t -> string -> Yojson.Safe.t -> unit

  (** Register event handler *)
  val on_change : t -> (Yojson.Safe.t -> unit) -> unit
  val on_click : t -> (unit -> unit) -> unit

  (** Display / close *)
  val display : t -> unit
  val close : t -> unit
end
```

**Important**: This API library (`widget` or similar) runs *inside* the toplevel
and must have minimal dependencies. It communicates with the frontend by pushing
messages through the same channel as `Mime_printer`.

## Code Removal Plan

### Files to Remove

| File | Reason |
|------|--------|
| `idl/transport.ml`, `transport.mli` | JSON-RPC transport wrapper |
| `idl/js_top_worker_client.ml`, `.mli` | RPC-based Lwt client |
| `idl/js_top_worker_client_fut.ml` | RPC-based Fut client |
| `idl/_old/` directory | Historical RPC reference code |

### Dependencies to Remove

| Package | Used By |
|---------|---------|
| `rpclib` | transport.ml, RPC clients |
| `rpclib-lwt` | impl.ml (IdlM module) |
| `rpclib.json` | transport.ml, RPC clients |
| `ppx_deriving_rpc` | toplevel_api.ml code generation |
| `xmlm` | transitive via rpclib |
| `cmdliner` | transitive via rpclib |

### Files to Refactor

| File | Change |
|------|--------|
| `lib/impl.ml` | Remove `IdlM` / `Rpc_lwt` usage, use own types |
| `idl/toplevel_api.ml` | Keep type definitions, remove RPC IDL machinery |
| `idl/toplevel_api_gen.ml` | Replace with hand-written types (no ppx_deriving_rpc) |
| `idl/dune` | Remove rpclib library deps and ppx rules |
| `lib/dune` | Remove rpclib-lwt dep |
| `test/node/*.ml` | Migrate from RPC Server/Client to message protocol |
| `test/browser/client_test.ml` | Use message-based client |
| `example/unix_worker.ml` | Use message protocol over Unix socket |
| `example/unix_client.ml` | Use message protocol over Unix socket |

### Impact on `toplevel_api_gen.ml`

The generated file is 92k+ lines (from ppx_deriving_rpc). The types it defines
are used extensively in `impl.ml` and `worker.ml`. The plan:

1. Extract the **type definitions** into a new lightweight module (no ppx)
2. Hand-write any needed serialization for the message protocol
3. Remove `ppx_deriving_rpc` dependency entirely
4. Delete `toplevel_api_gen.ml`

## Testing Strategy

### Existing Test Infrastructure

| Backend | Location | Framework |
|---------|----------|-----------|
| Unit tests | `test/libtest/` | ppx_expect |
| Node.js | `test/node/` | js_of_ocaml + Node |
| Unix (cram) | `test/cram/` | Cram tests with unix_worker |
| Browser | `test/browser/` | Playwright + Chromium |

### Widget Testing Approach

#### 1. Unit Tests (`test/libtest/`)

- Widget state management logic
- Message serialization/deserialization for widget messages
- CommManager state tracking (open/update/close lifecycle)

#### 2. Node.js Tests (`test/node/`)

- Widget creation produces correct CommOpen messages
- Widget state updates produce CommUpdate messages
- Event handler registration and dispatch
- Widget close cleanup
- Multiple simultaneous widgets
- Widget interaction with regular exec output (mime_vals + widgets)

#### 3. Cram Tests (`test/cram/`)

- Unix worker handles widget messages over socket
- Widget lifecycle via command-line client
- Widget messages interleaved with regular eval output

#### 4. Browser Tests (`test/browser/`)

- **End-to-end widget rendering**: OCaml creates widget -> message sent ->
  client renders DOM element -> user interaction -> event sent back -> OCaml
  handler fires
- **Widget types**: Test each widget type (slider, button, text, dropdown,
  checkbox, html)
- **State synchronization**: Frontend changes propagated to worker and back
- **Multiple widgets**: Several widgets active simultaneously
- **Widget cleanup**: Closing widgets removes DOM elements
- **Integration with existing features**: Widgets alongside code completion,
  error reporting, MIME output

### Test Utilities

A shared test helper module for widget testing:

```ocaml
(* test/test_widget_helpers.ml *)
val assert_comm_open : worker_msg -> comm_id:string -> widget_type:string -> unit
val assert_comm_update : worker_msg -> comm_id:string -> key:string -> unit
val assert_comm_close : worker_msg -> comm_id:string -> unit
val simulate_event : comm_id:string -> data:string -> client_msg
```

## Example Widgets

### Priority 1: Core Widgets (Implement First)

These are the most commonly used Jupyter widgets and cover the fundamental
interaction patterns:

| Widget | State | Events | Jupyter Equivalent |
|--------|-------|--------|--------------------|
| IntSlider | value, min, max, step | on_change(int) | IntSlider |
| Button | description, style | on_click | Button |
| Text | value, placeholder | on_change(string) | Text |
| Dropdown | value, options | on_change(string) | Dropdown |
| Checkbox | value, description | on_change(bool) | Checkbox |
| HTML | value (html string) | none | HTML |

### Priority 2: Composition Widgets

| Widget | Purpose | Jupyter Equivalent |
|--------|---------|-------------------|
| HBox / VBox | Layout containers | HBox / VBox |
| Output | Capture stdout/display | Output |
| FloatSlider | Decimal slider | FloatSlider |

### Priority 3: Domain-Specific Widgets

| Widget | Purpose | Inspired By |
|--------|---------|-------------|
| Plot | Simple 2D charts (SVG) | bqplot (simplified) |
| Table | Data grid display | ipydatagrid (read-only) |
| Image | Display image bytes | Image widget |

### Example: Interactive Slider

```ocaml
(* User code in toplevel *)
let threshold = Widget.slider ~min:0 ~max:100 ~description:"Threshold" 50;;

Widget.on_change threshold (fun v ->
  let n = Widget.Int.of_json v in
  Printf.printf "Threshold changed to: %d\n" n
);;
```

### Example: Button with Output

```ocaml
let count = ref 0;;
let label = Widget.html (Printf.sprintf "<b>Count: %d</b>" !count);;
let btn = Widget.button "Increment";;

Widget.on_click btn (fun () ->
  incr count;
  Widget.set label "value"
    (`String (Printf.sprintf "<b>Count: %d</b>" !count))
);;
```

### Example: Linked Widgets

```ocaml
let slider = Widget.slider ~min:0 ~max:255 ~description:"Red" 128;;
let preview = Widget.html {|<div style="width:50px;height:50px"></div>|};;

Widget.on_change slider (fun v ->
  let r = Widget.Int.of_json v in
  Widget.set preview "value"
    (`String (Printf.sprintf
      {|<div style="width:50px;height:50px;background:rgb(%d,0,0)"></div>|} r))
);;
```

## Implementation Phases

### Phase 1: RPC Removal & Type Cleanup

Remove the legacy RPC layer and establish clean type definitions.

### Phase 2: Widget Message Protocol

Extend `message.ml` and `worker.ml` with widget message types.

### Phase 3: Widget Manager (Worker Side)

Implement the comm manager that tracks widget state and routes events.

### Phase 4: OCaml Widget API

Create the user-facing `Widget` module available in the toplevel.

### Phase 5: JavaScript Widget Renderer

Implement widget rendering in the JavaScript client.

### Phase 6: Testing & Examples

Full test coverage across all backends, example widgets, documentation.

## Open Questions

1. **JSON representation in OCaml API**: Use `Yojson.Safe.t`? A custom minimal
   JSON type? Raw `Js.Unsafe.any`? (Yojson adds a dependency; custom type is
   more work; Unsafe.any is untyped.)

2. **Widget library loading**: Should the Widget module be preloaded in the
   worker, or loaded on demand via `#require "widget"`?

3. **Layout model**: How much of Jupyter's CSS-based layout model to support?
   Full flexbox control per-widget, or simpler HBox/VBox only?

4. **Persistence**: Should widget state survive cell re-execution? Jupyter
   widgets are destroyed and recreated; we could do the same or preserve state.
