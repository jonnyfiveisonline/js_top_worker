(** Browser test for js_top_worker_client library.

    This test runs in a browser via Playwright and exercises:
    - Worker spawning
    - RPC communication via postMessage
    - Timeout handling
    - All W module functions *)

open Js_of_ocaml
open Js_top_worker_rpc
module W = Js_top_worker_client.W

(* Test result tracking *)
type test_result = { name : string; passed : bool; message : string }

let results : test_result list ref = ref []

let log s = Console.console##log (Js.string s)

let add_result name passed message =
  results := { name; passed; message } :: !results;
  let status = if passed then "PASS" else "FAIL" in
  log (Printf.sprintf "[%s] %s: %s" status name message)

let report_results () =
  let total = List.length !results in
  let passed = List.filter (fun r -> r.passed) !results |> List.length in
  let failed = total - passed in
  log (Printf.sprintf "\n=== Test Results: %d passed, %d failed ===" passed failed);
  List.iter (fun r ->
    let status = if r.passed then "OK" else "FAILED" in
    log (Printf.sprintf "  %s: %s - %s" status r.name r.message)
  ) (List.rev !results);
  (* Set a global variable for Playwright to check *)
  Js.Unsafe.set Js.Unsafe.global (Js.string "testResults")
    (object%js
       val total = total
       val passed = passed
       val failed = failed
       val done_ = Js._true
     end)

let test_init_and_setup rpc =
  let ( let* ) = Lwt_result.bind in
  let* () =
    W.init rpc
      Toplevel_api_gen.
        { stdlib_dcs = None; findlib_requires = []; execute = true }
  in
  add_result "init" true "Initialized successfully";
  let* _o = W.setup rpc "" in
  add_result "setup" true "Setup completed";
  Lwt.return (Ok ())

let test_exec rpc =
  let ( let* ) = Lwt_result.bind in
  let* o = W.exec rpc "" "let x = 1 + 2;;" in
  let has_output =
    match o.caml_ppf with Some s -> String.length s > 0 | None -> false
  in
  add_result "exec" has_output
    (Printf.sprintf "caml_ppf=%s"
       (Option.value ~default:"(none)" o.caml_ppf));
  Lwt.return (Ok ())

let test_exec_with_output rpc =
  let ( let* ) = Lwt_result.bind in
  let* o = W.exec rpc "" "print_endline \"hello from test\";;" in
  let has_stdout =
    match o.stdout with
    | Some s -> Astring.String.is_prefix ~affix:"hello" s
    | None -> false
  in
  add_result "exec_stdout" has_stdout
    (Printf.sprintf "stdout=%s" (Option.value ~default:"(none)" o.stdout));
  Lwt.return (Ok ())

let test_typecheck rpc =
  let ( let* ) = Lwt_result.bind in
  (* Valid code should typecheck *)
  let* o1 = W.typecheck rpc "" "let f x = x + 1;;" in
  let valid_ok = Option.is_none o1.stderr in
  add_result "typecheck_valid" valid_ok "Valid code typechecks";
  (* Invalid code should produce error *)
  let* o2 = W.typecheck rpc "" "let f x = x + \"string\";;" in
  let invalid_has_error = Option.is_some o2.stderr || Option.is_some o2.highlight in
  add_result "typecheck_invalid" invalid_has_error "Invalid code produces error";
  Lwt.return (Ok ())

let test_query_errors rpc =
  let ( let* ) = Lwt_result.bind in
  (* Test that query_errors RPC call works - result depends on context *)
  let* _errors = W.query_errors rpc "" (Some "test1") [] false "let x : int = \"foo\";;" in
  (* Success = the RPC call completed without error *)
  add_result "query_errors" true "query_errors RPC call succeeded";
  Lwt.return (Ok ())

let run_tests worker_url =
  let ( let* ) = Lwt.bind in
  log (Printf.sprintf "Starting tests with worker: %s" worker_url);
  let rpc =
    Js_top_worker_client.start worker_url 30000 (fun () ->
        add_result "timeout" false "Unexpected timeout")
  in
  let test_sequence =
    let ( let* ) = Lwt_result.bind in
    let* () = test_init_and_setup rpc in
    let* () = test_exec rpc in
    let* () = test_exec_with_output rpc in
    let* () = test_typecheck rpc in
    let* () = test_query_errors rpc in
    Lwt.return (Ok ())
  in
  let* result = test_sequence in
  (match result with
  | Ok () -> add_result "all_tests" true "All tests completed"
  | Error (Toplevel_api_gen.InternalError msg) ->
      add_result "all_tests" false (Printf.sprintf "Error: %s" msg));
  report_results ();
  Lwt.return ()

let () =
  (* Use test_worker.bc.js by default *)
  ignore (run_tests "test_worker.bc.js")
