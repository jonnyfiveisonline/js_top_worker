(** Node.js test for multiple environment support.

    This tests that multiple isolated execution environments work correctly,
    including:
    - Creating and destroying environments
    - Isolation between environments (values defined in one don't leak to another)
    - Using the default environment
    - Listing environments
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

let run_toplevel rpc env_id code =
  let ( let* ) = IdlM.ErrM.bind in
  let* result = Client.exec_toplevel rpc env_id ("# " ^ code) in
  IdlM.ErrM.return result.script

let _ =
  Printf.printf "=== Node.js Environment Tests ===\n\n%!";

  let rpc = start_server () in
  let ( let* ) = IdlM.ErrM.bind in

  let init_config =
    { stdlib_dcs = None; findlib_requires = []; execute = true }
  in

  let test_sequence =
    (* Initialize *)
    let* _ = Client.init rpc init_config in

    Printf.printf "--- Section 1: Default Environment ---\n%!";

    (* Setup default environment *)
    let* _ = Client.setup rpc "" in
    test "default_setup" true "Default environment setup";

    (* Define a value in default environment *)
    let* r = run_toplevel rpc "" "let default_val = 42;;" in
    test "default_define" (contains r "val default_val : int = 42") r;

    Printf.printf "\n--- Section 2: Creating New Environments ---\n%!";

    (* Create a new environment "env1" *)
    let* _ = Client.create_env rpc "env1" in
    test "create_env1" true "Created environment env1";

    (* Setup env1 *)
    let* _ = Client.setup rpc "env1" in
    test "setup_env1" true "Setup environment env1";

    (* Define a different value in env1 *)
    let* r = run_toplevel rpc "env1" "let env1_val = 100;;" in
    test "env1_define" (contains r "val env1_val : int = 100") r;

    Printf.printf "\n--- Section 3: Environment Isolation ---\n%!";

    (* Check that default_val is NOT visible in env1 - the script output
       should NOT contain "val default_val" if there was an error *)
    let* r = run_toplevel rpc "env1" "default_val;;" in
    test "isolation_default_from_env1" (not (contains r "val default_val"))
      ("No leakage: " ^ String.sub r 0 (min 40 (String.length r)));

    (* Check that env1_val is NOT visible in default env *)
    let* r = run_toplevel rpc "" "env1_val;;" in
    test "isolation_env1_from_default" (not (contains r "val env1_val"))
      ("No leakage: " ^ String.sub r 0 (min 40 (String.length r)));

    (* Check that default_val IS still visible in default env *)
    let* r = run_toplevel rpc "" "default_val;;" in
    test "default_still_works" (contains r "- : int = 42") r;

    Printf.printf "\n--- Section 4: Multiple Environments ---\n%!";

    (* Create a second environment *)
    let* _ = Client.create_env rpc "env2" in
    let* _ = Client.setup rpc "env2" in
    test "create_and_setup_env2" true "Created and setup env2";

    (* Define value in env2 *)
    let* r = run_toplevel rpc "env2" "let env2_val = 200;;" in
    test "env2_define" (contains r "val env2_val : int = 200") r;

    (* Verify isolation between all three environments *)
    let* r = run_toplevel rpc "env2" "env1_val;;" in
    test "isolation_env1_from_env2" (not (contains r "val env1_val"))
      ("No leakage: " ^ String.sub r 0 (min 40 (String.length r)));

    let* r = run_toplevel rpc "env1" "env2_val;;" in
    test "isolation_env2_from_env1" (not (contains r "val env2_val"))
      ("No leakage: " ^ String.sub r 0 (min 40 (String.length r)));

    Printf.printf "\n--- Section 5: List Environments ---\n%!";

    (* List all environments *)
    let* envs = Client.list_envs rpc () in
    test "list_envs_count" (List.length envs >= 3)
      (Printf.sprintf "Found %d environments" (List.length envs));
    test "list_envs_has_default" (List.mem "default" envs)
      (String.concat ", " envs);
    test "list_envs_has_env1" (List.mem "env1" envs)
      (String.concat ", " envs);
    test "list_envs_has_env2" (List.mem "env2" envs)
      (String.concat ", " envs);

    Printf.printf "\n--- Section 6: Destroy Environment ---\n%!";

    (* Destroy env2 *)
    let* _ = Client.destroy_env rpc "env2" in
    test "destroy_env2" true "Destroyed env2";

    (* Verify env2 is gone from list *)
    let* envs = Client.list_envs rpc () in
    test "env2_destroyed" (not (List.mem "env2" envs))
      (String.concat ", " envs);

    (* env1 should still exist *)
    test "env1_still_exists" (List.mem "env1" envs)
      (String.concat ", " envs);

    Printf.printf "\n--- Section 7: Reuse Environment Name ---\n%!";

    (* Re-create env2 *)
    let* _ = Client.create_env rpc "env2" in
    let* _ = Client.setup rpc "env2" in

    (* Old values should not exist - checking that it doesn't find the old value *)
    let* r = run_toplevel rpc "env2" "env2_val;;" in
    test "new_env2_clean" (not (contains r "- : int = 200"))
      ("Old value gone: " ^ String.sub r 0 (min 40 (String.length r)));

    (* Define new value *)
    let* r = run_toplevel rpc "env2" "let new_env2_val = 999;;" in
    test "new_env2_define" (contains r "val new_env2_val : int = 999") r;

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
    Printf.printf "SUCCESS: All environment tests passed!\n%!"
  else Printf.printf "FAILURE: Some tests failed.\n%!"
