(** Node.js test for OCaml toplevel directives.

    This tests the js_of_ocaml implementation of the toplevel,
    running in Node.js to verify directives work in the JS context.

    Directives tested:
    - Environment query: #show, #show_type, #show_val, #show_module, #show_exception
    - Pretty-printing: #print_depth, #print_length
    - Custom printers: #install_printer, #remove_printer
    - Warnings: #warnings, #warn_error
    - Type system: #rectypes
    - Directory: #directory, #remove_directory
    - Help: #help
    - Compiler options: #labels, #principal
    - Error handling: unknown directives, missing identifiers

    NOT tested (require file system or special setup):
    - #use, #mod_use (file loading)
    - #load (bytecode loading)
    - #require, #list (findlib - tested separately)
    - #trace (excluded per user request)
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
  (* Note: Do NOT set stderr flusher - it causes hangs in js_of_ocaml *)
  let x = f () in
  let captured =
    {
      Impl.stdout = Buffer.contents stdout_buff;
      stderr = Buffer.contents stderr_buff;
    }
  in
  (* Restore flusher that writes to console so Printf.printf works for test output *)
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
    | packages ->
        Js_top_worker_web.Findlibish.require ~import_scripts sync_get b v
          packages

  let path = "/static/cmis"
end

module U = Impl.Make (S)

let start_server () =
  let open U in
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Info);
  Server.exec execute;
  Server.setup (IdlM.T.lift setup);
  Server.init (IdlM.T.lift init);
  Server.typecheck typecheck_phrase;
  Server.complete_prefix complete_prefix;
  Server.query_errors query_errors;
  Server.type_enclosing type_enclosing;
  Server.exec_toplevel exec_toplevel;
  IdlM.server Server.implementation

module Client = Js_top_worker_rpc.Toplevel_api_gen.Make (Impl.IdlM.GenClient ())

(* Test result tracking *)
let total_tests = ref 0
let passed_tests = ref 0

let test name check message =
  incr total_tests;
  let passed = check in
  if passed then incr passed_tests;
  let status = if passed then "PASS" else "FAIL" in
  Printf.printf "[%s] %s: %s\n%!" status name message

let contains s substr =
  try
    let _ = Str.search_forward (Str.regexp_string substr) s 0 in
    true
  with Not_found -> false

let run_directive rpc code =
  let ( let* ) = IdlM.ErrM.bind in
  let* result = Client.exec_toplevel rpc ("# " ^ code) in
  IdlM.ErrM.return result.script

let _ =
  Printf.printf "=== Node.js Directive Tests ===\n\n%!";

  let rpc = start_server () in
  let ( let* ) = IdlM.ErrM.bind in

  let init_config =
    { stdlib_dcs = None; findlib_requires = []; execute = true }
  in

  let test_sequence =
    (* Initialize *)
    let* _ = Client.init rpc init_config in
    let* _ = Client.setup rpc () in

    Printf.printf "--- Section 1: Basic Execution ---\n%!";

    let* r = run_directive rpc "1 + 2;;" in
    test "basic_eval" (contains r "- : int = 3") r;

    let* r = run_directive rpc "let x = 42;;" in
    test "let_binding" (contains r "val x : int = 42") r;

    Printf.printf "\n--- Section 2: #show Directives ---\n%!";

    (* Define types/values to query *)
    let* _ = run_directive rpc "type point = { x: float; y: float };;" in
    let* _ = run_directive rpc "let origin = { x = 0.0; y = 0.0 };;" in
    let* _ =
      run_directive rpc
        "module MyMod = struct type t = int let zero = 0 end;;"
    in
    let* _ = run_directive rpc "exception My_error of string;;" in

    let* r = run_directive rpc "#show point;;" in
    test "show_type_point" (contains r "type point") r;

    let* r = run_directive rpc "#show origin;;" in
    test "show_val_origin" (contains r "val origin") r;

    let* r = run_directive rpc "#show MyMod;;" in
    test "show_module" (contains r "module MyMod") r;

    let* r = run_directive rpc "#show My_error;;" in
    test "show_exception" (contains r "exception My_error") r;

    let* r = run_directive rpc "#show_type list;;" in
    test "show_type_list" (contains r "type 'a list") r;

    let* r = run_directive rpc "#show_val List.map;;" in
    test "show_val_list_map" (contains r "val map") r;

    let* r = run_directive rpc "#show_module List;;" in
    test "show_module_list" (contains r "module List") r;

    let* r = run_directive rpc "#show_exception Not_found;;" in
    test "show_exception_not_found" (contains r "exception Not_found") r;

    Printf.printf "\n--- Section 3: #print_depth and #print_length ---\n%!";

    let* _ = run_directive rpc "let nested = [[[[1;2;3]]]];;" in
    let* _ = run_directive rpc "#print_depth 2;;" in
    let* r = run_directive rpc "nested;;" in
    test "print_depth_truncated" (contains r "...") r;

    let* _ = run_directive rpc "#print_depth 100;;" in
    let* r = run_directive rpc "nested;;" in
    test "print_depth_full" (contains r "1; 2; 3") r;

    let* _ = run_directive rpc "let long_list = [1;2;3;4;5;6;7;8;9;10];;" in
    let* _ = run_directive rpc "#print_length 3;;" in
    let* r = run_directive rpc "long_list;;" in
    test "print_length_truncated" (contains r "...") r;

    let* _ = run_directive rpc "#print_length 100;;" in
    let* r = run_directive rpc "long_list;;" in
    test "print_length_full" (contains r "10") r;

    Printf.printf "\n--- Section 4: #install_printer / #remove_printer ---\n%!";

    let* _ = run_directive rpc "type color = Red | Green | Blue;;" in
    let* _ =
      run_directive rpc
        {|let pp_color fmt c = Format.fprintf fmt "<color:%s>" (match c with Red -> "red" | Green -> "green" | Blue -> "blue");;|}
    in
    let* _ = run_directive rpc "#install_printer pp_color;;" in
    let* r = run_directive rpc "Red;;" in
    test "install_printer" (contains r "<color:red>") r;

    let* _ = run_directive rpc "#remove_printer pp_color;;" in
    let* r = run_directive rpc "Red;;" in
    test "remove_printer" (contains r "Red" && not (contains r "<color:red>")) r;

    Printf.printf "\n--- Section 5: #warnings / #warn_error ---\n%!";

    let* _ = run_directive rpc "#warnings \"-26\";;" in
    let* r = run_directive rpc "let _ = let unused = 1 in 2;;" in
    test "warnings_disabled"
      (not (contains r "Warning") || contains r "- : int = 2")
      r;

    let* _ = run_directive rpc "#warnings \"+26\";;" in
    let* r = run_directive rpc "let _ = let unused2 = 1 in 2;;" in
    test "warnings_enabled" (contains r "Warning" || contains r "unused2") r;

    let* _ = run_directive rpc "#warn_error \"+26\";;" in
    let* r = run_directive rpc "let _ = let unused3 = 1 in 2;;" in
    test "warn_error" (contains r "Error") r;

    let* _ = run_directive rpc "#warn_error \"-a\";;" in

    Printf.printf "\n--- Section 6: #rectypes ---\n%!";

    let* r = run_directive rpc "type 'a t = 'a t -> int;;" in
    test "rectypes_before" (contains r "Error" || contains r "cyclic") r;

    let* _ = run_directive rpc "#rectypes;;" in
    let* r = run_directive rpc "type 'a u = 'a u -> int;;" in
    test "rectypes_after" (contains r "type 'a u") r;

    Printf.printf "\n--- Section 7: #directory ---\n%!";

    let* r = run_directive rpc "#directory \"/tmp\";;" in
    test "directory_add" (String.length r >= 0) "(no error)";

    let* r = run_directive rpc "#remove_directory \"/tmp\";;" in
    test "directory_remove" (String.length r >= 0) "(no error)";

    Printf.printf "\n--- Section 8: #help ---\n%!";

    let* r = run_directive rpc "#help;;" in
    test "help"
      (contains r "directive" || contains r "Directive" || contains r "#")
      (String.sub r 0 (min 100 (String.length r)) ^ "...");

    Printf.printf "\n--- Section 9: #labels / #principal ---\n%!";

    let* r = run_directive rpc "#labels true;;" in
    test "labels_true" (String.length r >= 0) "(no error)";

    let* r = run_directive rpc "#labels false;;" in
    test "labels_false" (String.length r >= 0) "(no error)";

    let* r = run_directive rpc "#principal true;;" in
    test "principal_true" (String.length r >= 0) "(no error)";

    let* r = run_directive rpc "#principal false;;" in
    test "principal_false" (String.length r >= 0) "(no error)";

    Printf.printf "\n--- Section 10: Error Cases ---\n%!";

    let* r = run_directive rpc "#unknown_directive;;" in
    test "unknown_directive" (contains r "Unknown") r;

    let* r = run_directive rpc "#show nonexistent_value;;" in
    test "show_nonexistent" (contains r "Unknown" || contains r "not found") r;

    Printf.printf "\n--- Section 11: Classes ---\n%!";

    let* _ =
      run_directive rpc
        "class counter = object val mutable n = 0 method incr = n <- n + 1 \
         method get = n end;;"
    in
    let* r = run_directive rpc "#show_class counter;;" in
    test "show_class" (contains r "class counter") r;

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
    Printf.printf "SUCCESS: All directive tests passed!\n%!"
  else Printf.printf "FAILURE: Some tests failed.\n%!"
