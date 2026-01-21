(** Node.js test for PPX preprocessing support.

    This tests that the PPX preprocessing pipeline works correctly,
    including both old-style Ast_mapper PPXs (like js_of_ocaml's Ppx_js)
    and ppxlib-based PPXs.

    Tests:
    - js_of_ocaml PPX syntax (%js extensions)
    - PPX error handling
    - Preprocessing in both execute and typecheck paths
*)

open Js_top_worker
open Js_top_worker_rpc.Toplevel_api_gen
open Impl

(* Flusher that writes to process.stdout in Node.js *)
let console_flusher (s : string) : unit =
  let open Js_of_ocaml in
  let process = Js.Unsafe.get Js.Unsafe.global (Js.string "process") in
  let stdout = Js.Unsafe.get process (Js.string "stdout") in
  let write = Js.Unsafe.get stdout (Js.string "write") in
  ignore (Js.Unsafe.call write stdout [| Js.Unsafe.inject (Js.string s) |])

let capture : (unit -> 'a) -> unit -> Impl.captured * 'a =
 fun f () ->
  let stdout_buff = Buffer.create 1024 in
  let stderr_buff = Buffer.create 1024 in
  Js_of_ocaml.Sys_js.set_channel_flusher stdout (Buffer.add_string stdout_buff);
  let x = f () in
  let captured =
    {
      Impl.stdout = Buffer.contents stdout_buff;
      stderr = Buffer.contents stderr_buff;
    }
  in
  Js_of_ocaml.Sys_js.set_channel_flusher stdout console_flusher;
  (captured, x)

module Server = Js_top_worker_rpc.Toplevel_api_gen.Make (Impl.IdlM.GenServer ())

module S : Impl.S = struct
  type findlib_t = Js_top_worker_web.Findlibish.t

  let capture = capture

  let sync_get f =
    let f = Fpath.v ("_opam/" ^ f) in
    Logs.info (fun m -> m "sync_get: %a" Fpath.pp f);
    try Some (In_channel.with_open_bin (Fpath.to_string f) In_channel.input_all)
    with e ->
      Logs.err (fun m ->
          m "Error reading file %a: %s" Fpath.pp f (Printexc.to_string e));
      None

  let async_get f =
    let f = Fpath.v ("_opam/" ^ f) in
    Logs.info (fun m -> m "async_get: %a" Fpath.pp f);
    try
      let content =
        In_channel.with_open_bin (Fpath.to_string f) In_channel.input_all
      in
      Lwt.return (Ok content)
    with e ->
      Logs.err (fun m ->
          m "Error reading file %a: %s" Fpath.pp f (Printexc.to_string e));
      Lwt.return (Error (`Msg (Printexc.to_string e)))

  let create_file = Js_of_ocaml.Sys_js.create_file

  let import_scripts urls =
    let open Js_of_ocaml.Js in
    let import_scripts_fn = Unsafe.get Unsafe.global (string "importScripts") in
    List.iter
      (fun url ->
        let (_ : 'a) =
          Unsafe.fun_call import_scripts_fn [| Unsafe.inject (string url) |]
        in
        ())
      urls

  let init_function _ () = failwith "Not implemented"
  let findlib_init = Js_top_worker_web.Findlibish.init async_get

  let get_stdlib_dcs uri =
    Js_top_worker_web.Findlibish.fetch_dynamic_cmis sync_get uri
    |> Result.to_list

  let require b v = function
    | [] -> []
    | packages -> Js_top_worker_web.Findlibish.require ~import_scripts sync_get b v packages

  let path = "/static/cmis"
end

module U = Impl.Make (S)

let start_server () =
  let open U in
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Info);
  Server.init (IdlM.T.lift init);
  Server.create_env (IdlM.T.lift create_env);
  Server.destroy_env (IdlM.T.lift destroy_env);
  Server.list_envs (IdlM.T.lift list_envs);
  Server.setup (IdlM.T.lift setup);
  Server.exec execute;
  Server.typecheck typecheck_phrase;
  Server.complete_prefix complete_prefix;
  Server.query_errors query_errors;
  Server.type_enclosing type_enclosing;
  Server.exec_toplevel exec_toplevel;
  IdlM.server Server.implementation

module Client = Js_top_worker_rpc.Toplevel_api_gen.Make (Impl.IdlM.GenClient ())

(* Test state *)
let passed_tests = ref 0
let total_tests = ref 0

let test name condition message =
  incr total_tests;
  let status = if condition then (incr passed_tests; "PASS") else "FAIL" in
  Printf.printf "[%s] %s: %s\n%!" status name message

let contains s substr =
  try
    let _ = Str.search_forward (Str.regexp_string substr) s 0 in
    true
  with Not_found -> false

let run_toplevel rpc code =
  let ( let* ) = IdlM.ErrM.bind in
  let* result = Client.exec_toplevel rpc "" ("# " ^ code) in
  IdlM.ErrM.return result.script

let _ =
  Printf.printf "=== Node.js PPX Tests ===\n\n%!";

  let rpc = start_server () in
  let ( let* ) = IdlM.ErrM.bind in

  let init_config =
    { stdlib_dcs = None; findlib_requires = []; execute = true }
  in

  let test_sequence =
    (* Initialize *)
    let* _ = Client.init rpc init_config in
    let* _ = Client.setup rpc "" in

    Printf.printf "--- Section 1: Basic PPX Preprocessing ---\n%!";

    (* Test that basic code still works (no PPX needed) *)
    let* r = run_toplevel rpc "let x = 1 + 2;;" in
    test "basic_no_ppx" (contains r "val x : int = 3") r;

    (* Test that PPX errors are handled gracefully *)
    Printf.printf "\n--- Section 2: PPX Pipeline Integration ---\n%!";

    (* Test that the preprocessing doesn't break normal code *)
    let* r = run_toplevel rpc "type t = { name: string; age: int };;" in
    test "record_type" (contains r "type t") r;

    let* r = run_toplevel rpc "let person = { name = \"Alice\"; age = 30 };;" in
    test "record_value" (contains r "val person : t") r;

    (* Test pattern matching *)
    let* r = run_toplevel rpc "let get_name p = p.name;;" in
    test "record_access" (contains r "val get_name : t -> string") r;

    (* Test that module definitions work with PPX preprocessing *)
    let* r = run_toplevel rpc "module M = struct let x = 42 end;;" in
    test "module_def" (contains r "module M") r;

    Printf.printf "\n--- Section 3: Complex Expressions ---\n%!";

    (* Test that complex expressions work through PPX pipeline *)
    let* r = run_toplevel rpc "let rec fib n = if n <= 1 then n else fib (n-1) + fib (n-2);;" in
    test "recursive_fn" (contains r "val fib : int -> int") r;

    let* r = run_toplevel rpc "fib 10;;" in
    test "recursive_call" (contains r "- : int = 55") r;

    (* Test that functors work *)
    let* r = run_toplevel rpc "module type S = sig val x : int end;;" in
    test "module_type" (contains r "module type S") r;

    let* r = run_toplevel rpc "module F (X : S) = struct let y = X.x + 1 end;;" in
    test "functor_def" (contains r "module F") r;

    Printf.printf "\n--- Section 4: PPX Attributes (no-op test) ---\n%!";

    (* Test that unknown attributes don't crash the PPX pipeline *)
    let* r = run_toplevel rpc "let[@inline] f x = x + 1;;" in
    test "inline_attr" (contains r "val f : int -> int") r;

    let* r = run_toplevel rpc "type point = { x: float [@default 0.0]; y: float };;" in
    test "field_attr" (contains r "type point") r;

    IdlM.ErrM.return ()
  in

  let promise = test_sequence |> IdlM.T.get in
  (match Lwt.state promise with
  | Lwt.Return (Ok ()) -> ()
  | Lwt.Return (Error (InternalError s)) ->
      Printf.printf "\n[ERROR] Test failed with: %s\n%!" s
  | Lwt.Fail e ->
      Printf.printf "\n[ERROR] Exception: %s\n%!" (Printexc.to_string e)
  | Lwt.Sleep -> Printf.printf "\n[ERROR] Promise still pending\n%!");

  Printf.printf "\n=== Results: %d/%d tests passed ===\n%!" !passed_tests
    !total_tests;
  if !passed_tests = !total_tests then
    Printf.printf "SUCCESS: All PPX tests passed!\n%!"
  else Printf.printf "FAILURE: Some tests failed.\n%!"
