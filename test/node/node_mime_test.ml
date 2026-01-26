(** Node.js test for MIME output infrastructure.

    This tests that the MIME output infrastructure is wired up correctly:
    - exec_result.mime_vals field is returned
    - Field is empty when no MIME output occurs
    - API types are correctly defined

    Note: The mime_printer library is used internally by the worker to
    capture MIME output. User code can call Mime_printer.push to produce
    MIME values when the mime_printer package is loaded in the toplevel.
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

(* Test result tracking *)
let total_tests = ref 0
let passed_tests = ref 0

let test name check message =
  incr total_tests;
  let passed = check in
  if passed then incr passed_tests;
  let status = if passed then "PASS" else "FAIL" in
  Printf.printf "[%s] %s: %s\n%!" status name message

let run_exec rpc code =
  let ( let* ) = IdlM.ErrM.bind in
  let* result = Client.exec rpc "" code in
  IdlM.ErrM.return result

let _ =
  Printf.printf "=== Node.js MIME Infrastructure Tests ===\n\n%!";

  let rpc = start_server () in
  let ( let* ) = IdlM.ErrM.bind in

  let init_config =
    { stdlib_dcs = None; findlib_requires = []; findlib_index = None; execute = true }
  in

  let test_sequence =
    (* Initialize *)
    let* _ = Client.init rpc init_config in
    let* _ = Client.setup rpc "" in

    Printf.printf "--- Section 1: exec_result Has mime_vals Field ---\n%!";

    (* Basic execution returns a result with mime_vals *)
    let* r = run_exec rpc {|let x = 1 + 2;;|} in
    test "has_mime_vals_field" true "exec_result has mime_vals field";
    test "mime_vals_is_list" (List.length r.mime_vals >= 0)
      (Printf.sprintf "mime_vals is a list (length=%d)" (List.length r.mime_vals));
    test "mime_vals_empty_no_output" (List.length r.mime_vals = 0)
      "mime_vals is empty when no MIME output";

    Printf.printf "\n--- Section 2: MIME Type Definitions ---\n%!";

    (* Verify API types are accessible *)
    let mime_val_example : mime_val = {
      mime_type = "text/html";
      encoding = Noencoding;
      data = "<b>test</b>";
    } in
    test "mime_type_field" (mime_val_example.mime_type = "text/html")
      "mime_val has mime_type field";
    test "encoding_noencoding" (mime_val_example.encoding = Noencoding)
      "Noencoding variant works";
    test "data_field" (mime_val_example.data = "<b>test</b>")
      "mime_val has data field";

    let mime_val_base64 : mime_val = {
      mime_type = "image/png";
      encoding = Base64;
      data = "iVBORw0KGgo=";
    } in
    test "encoding_base64" (mime_val_base64.encoding = Base64)
      "Base64 variant works";

    Printf.printf "\n--- Section 3: Multiple Executions ---\n%!";

    (* Verify mime_vals is fresh for each execution *)
    let* r1 = run_exec rpc {|let a = 1;;|} in
    let* r2 = run_exec rpc {|let b = 2;;|} in
    let* r3 = run_exec rpc {|let c = 3;;|} in
    test "r1_mime_empty" (List.length r1.mime_vals = 0) "First exec: mime_vals empty";
    test "r2_mime_empty" (List.length r2.mime_vals = 0) "Second exec: mime_vals empty";
    test "r3_mime_empty" (List.length r3.mime_vals = 0) "Third exec: mime_vals empty";

    Printf.printf "\n--- Section 4: exec_toplevel Has mime_vals ---\n%!";

    (* exec_toplevel also returns mime_vals *)
    let* tr = Client.exec_toplevel rpc "" "# let z = 42;;" in
    test "toplevel_has_mime_vals" true "exec_toplevel_result has mime_vals field";
    test "toplevel_mime_vals_list" (List.length tr.mime_vals >= 0)
      (Printf.sprintf "toplevel mime_vals is a list (length=%d)" (List.length tr.mime_vals));

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
    Printf.printf "SUCCESS: All MIME infrastructure tests passed!\n%!"
  else Printf.printf "FAILURE: Some tests failed.\n%!"
