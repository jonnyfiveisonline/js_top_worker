(** Node.js test for PPX preprocessing support.

    This tests that the PPX preprocessing pipeline works correctly with
    ppx_deriving. We verify that:
    1. [@@deriving show] generates working pp and show functions
    2. [@@deriving eq] generates working equal functions
    3. Multiple derivers work together
    4. Basic code still works through the PPX pipeline

    The PPX pipeline in js_top_worker applies old-style Ast_mapper PPXs
    followed by ppxlib-based PPXs via Ppxlib.Driver.map_structure.
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
    try Some (In_channel.with_open_bin (Fpath.to_string f) In_channel.input_all)
    with _ -> None

  let async_get f =
    let f = Fpath.v ("_opam/" ^ f) in
    try
      let content =
        In_channel.with_open_bin (Fpath.to_string f) In_channel.input_all
      in
      Lwt.return (Ok content)
    with e -> Lwt.return (Error (`Msg (Printexc.to_string e)))

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
    { stdlib_dcs = None; findlib_requires = []; findlib_index = None; execute = true }
  in

  let test_sequence =
    (* Initialize *)
    let* _ = Client.init rpc init_config in
    let* _ = Client.setup rpc "" in

    Printf.printf "--- Loading PPX dynamically ---\n%!";

    (* Dynamically load ppx_deriving.show - this should:
       1. Load the PPX deriver (registers with ppxlib)
       2. Auto-load ppx_deriving.runtime (via findlibish -ppx_driver predicate) *)
    let* r = run_toplevel rpc "#require \"ppx_deriving.show\";;" in
    test "load_ppx_show" (not (contains r "Error"))
      (if contains r "Error" then r else "ppx_deriving.show loaded");

    (* Also load eq deriver *)
    let* r = run_toplevel rpc "#require \"ppx_deriving.eq\";;" in
    test "load_ppx_eq" (not (contains r "Error"))
      (if contains r "Error" then r else "ppx_deriving.eq loaded");

    Printf.printf "\n--- Section 1: ppx_deriving.show ---\n%!";

    (* Test [@@deriving show] generates pp and show functions *)
    let* r = run_toplevel rpc "type color = Red | Green | Blue [@@deriving show];;" in
    test "show_type_defined" (contains r "type color") "type color defined";
    test "show_pp_generated" (contains r "val pp_color")
      (if contains r "val pp_color" then "pp_color generated" else r);
    test "show_fn_generated" (contains r "val show_color")
      (if contains r "val show_color" then "show_color generated" else r);

    (* Test the generated show function works *)
    let* r = run_toplevel rpc "show_color Red;;" in
    test "show_fn_works" (contains r "Red")
      (String.sub r 0 (min 60 (String.length r)));

    (* Test with a record type *)
    let* r = run_toplevel rpc "type point = { x: int; y: int } [@@deriving show];;" in
    test "show_record_type" (contains r "type point") "point type defined";
    test "show_record_pp" (contains r "val pp_point")
      (if contains r "val pp_point" then "pp_point generated" else r);

    let* r = run_toplevel rpc "show_point { x = 10; y = 20 };;" in
    test "show_record_works" (contains r "10" && contains r "20")
      (String.sub r 0 (min 60 (String.length r)));

    Printf.printf "\n--- Section 2: ppx_deriving.eq ---\n%!";

    (* Test [@@deriving eq] generates equal function *)
    let* r = run_toplevel rpc "type status = Active | Inactive [@@deriving eq];;" in
    test "eq_type_defined" (contains r "type status") "status type defined";
    test "eq_fn_generated" (contains r "val equal_status")
      (if contains r "val equal_status" then "equal_status generated" else r);

    (* Test the generated equal function works *)
    let* r = run_toplevel rpc "equal_status Active Active;;" in
    test "eq_same_true" (contains r "true") r;

    let* r = run_toplevel rpc "equal_status Active Inactive;;" in
    test "eq_diff_false" (contains r "false") r;

    Printf.printf "\n--- Section 3: Combined Derivers ---\n%!";

    (* Test multiple derivers on one type *)
    let* r = run_toplevel rpc "type expr = Num of int | Add of expr * expr [@@deriving show, eq];;" in
    test "combined_type" (contains r "type expr") "expr type defined";
    test "combined_pp" (contains r "val pp_expr")
      (if contains r "val pp_expr" then "pp_expr generated" else r);
    test "combined_eq" (contains r "val equal_expr")
      (if contains r "val equal_expr" then "equal_expr generated" else r);

    (* Test they work together *)
    let* r = run_toplevel rpc "let e1 = Add (Num 1, Num 2);;" in
    test "combined_value" (contains r "val e1") r;

    let* r = run_toplevel rpc "show_expr e1;;" in
    test "combined_show_works" (contains r "Add" || contains r "Num")
      (String.sub r 0 (min 80 (String.length r)));

    let* r = run_toplevel rpc "equal_expr e1 e1;;" in
    test "combined_eq_self" (contains r "true") r;

    let* r = run_toplevel rpc "equal_expr e1 (Num 1);;" in
    test "combined_eq_diff" (contains r "false") r;

    Printf.printf "\n--- Section 4: Basic Code Still Works ---\n%!";

    (* Verify normal code without PPX still works *)
    let* r = run_toplevel rpc "let x = 1 + 2;;" in
    test "basic_arithmetic" (contains r "val x : int = 3") r;

    let* r = run_toplevel rpc "let rec fib n = if n <= 1 then n else fib (n-1) + fib (n-2);;" in
    test "recursive_fn" (contains r "val fib : int -> int") r;

    let* r = run_toplevel rpc "fib 10;;" in
    test "fib_result" (contains r "55") r;

    Printf.printf "\n--- Section 5: Module Support ---\n%!";

    let* r = run_toplevel rpc "module M = struct type t = A | B [@@deriving show] end;;" in
    test "module_with_deriving" (contains r "module M") r;

    let* r = run_toplevel rpc "M.show_t M.A;;" in
    test "module_show_works" (contains r "A")
      (String.sub r 0 (min 60 (String.length r)));

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
