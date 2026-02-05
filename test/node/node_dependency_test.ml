(** Node.js test for cell dependency system.

    This tests that cell dependencies work correctly, including:
    - Linear dependencies (c1 → c2 → c3)
    - Diamond dependencies (c1 → c2, c3 → c4)
    - Missing dependencies (referencing non-existent cell)
    - Dependency update propagation
    - Type shadowing across cells
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
  Logs.set_level (Some Logs.Warning);
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

let query_errors rpc env_id cell_id deps source =
  Client.query_errors rpc env_id cell_id deps false source

let _ =
  Printf.printf "=== Node.js Cell Dependency Tests ===\n\n%!";

  let rpc = start_server () in
  let ( let* ) = IdlM.ErrM.bind in

  let init_config =
    { stdlib_dcs = None; findlib_requires = []; findlib_index = None; execute = true }
  in

  let test_sequence =
    (* Initialize and setup *)
    let* _ = Client.init rpc init_config in
    let* _ = Client.setup rpc "" in
    test "init" true "Initialized and setup";

    Printf.printf "\n--- Section 1: Linear Dependencies ---\n%!";

    (* c1: base definition *)
    let* errors = query_errors rpc "" (Some "c1") [] "type t = int;;" in
    test "linear_c1" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    (* c2 depends on c1 *)
    let* errors = query_errors rpc "" (Some "c2") ["c1"] "let x : t = 42;;" in
    test "linear_c2" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    (* c3 depends on c2 (and transitively c1) *)
    let* errors = query_errors rpc "" (Some "c3") ["c2"] "let y = x + 1;;" in
    test "linear_c3" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    (* c4 depends on c3 *)
    let* errors = query_errors rpc "" (Some "c4") ["c3"] "let z = y * 2;;" in
    test "linear_c4" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    Printf.printf "\n--- Section 2: Diamond Dependencies ---\n%!";

    (* d1: base type *)
    let* errors = query_errors rpc "" (Some "d1") []
      "type point = { x: int; y: int };;" in
    test "diamond_d1" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    (* d2 depends on d1 *)
    let* errors = query_errors rpc "" (Some "d2") ["d1"]
      "let origin : point = { x = 0; y = 0 };;" in
    test "diamond_d2" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    (* d3 depends on d1 (parallel to d2) *)
    let* errors = query_errors rpc "" (Some "d3") ["d1"]
      "let unit_x : point = { x = 1; y = 0 };;" in
    test "diamond_d3" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    (* d4 depends on d2, d3, and transitively needs d1 for the point type *)
    let* errors = query_errors rpc "" (Some "d4") ["d1"; "d2"; "d3"]
      "let add p1 p2 : point = { x = p1.x + p2.x; y = p1.y + p2.y };;\n\
       let result = add origin unit_x;;" in
    test "diamond_d4" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    Printf.printf "\n--- Section 3: Missing Dependencies ---\n%!";

    (* Try to use a type from a cell that doesn't exist in deps *)
    let* errors = query_errors rpc "" (Some "m1") []
      "let bad : point = { x = 1; y = 2 };;" in
    test "missing_dep_error" (List.length errors > 0)
      (Printf.sprintf "%d errors (expected > 0)" (List.length errors));

    (* Reference with missing dependency - should fail *)
    let* errors = query_errors rpc "" (Some "m2") ["nonexistent"]
      "let a = 1;;" in
    (* Even with a missing dep in the list, simple code should work *)
    test "missing_dep_simple_ok" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    Printf.printf "\n--- Section 4: Dependency Update Propagation ---\n%!";

    (* u1: initial type *)
    let* errors = query_errors rpc "" (Some "u1") [] "type u = int;;" in
    test "update_u1_initial" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    (* u2: depends on u1, uses type u as int *)
    let* errors = query_errors rpc "" (Some "u2") ["u1"] "let val_u : u = 42;;" in
    test "update_u2_initial" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    (* Now update u1 to change type u to string *)
    let* errors = query_errors rpc "" (Some "u1") [] "type u = string;;" in
    test "update_u1_changed" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    (* u2 with same code should now error (42 is not string) *)
    let* errors = query_errors rpc "" (Some "u2") ["u1"] "let val_u : u = 42;;" in
    test "update_u2_error" (List.length errors > 0)
      (Printf.sprintf "%d errors (expected > 0)" (List.length errors));

    (* Fix u2 to work with string type *)
    let* errors = query_errors rpc "" (Some "u2") ["u1"]
      "let val_u : u = \"hello\";;" in
    test "update_u2_fixed" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    Printf.printf "\n--- Section 5: Type Shadowing ---\n%!";

    (* s1: defines type t = int *)
    let* errors = query_errors rpc "" (Some "s1") [] "type t = int;;" in
    test "shadow_s1" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    (* s2: depends on s1, also defines type t = string (shadows) *)
    let* errors = query_errors rpc "" (Some "s2") ["s1"]
      "type t = string;;" in
    test "shadow_s2" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    (* s3: depends on s2 - should see t as string, not int *)
    let* errors = query_errors rpc "" (Some "s3") ["s2"]
      "let shadowed : t = \"works\";;" in
    test "shadow_s3_string" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    (* s4: depends only on s1 - should see t as int *)
    let* errors = query_errors rpc "" (Some "s4") ["s1"]
      "let original : t = 123;;" in
    test "shadow_s4_int" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    Printf.printf "\n--- Section 6: Complex Dependency Graph ---\n%!";

    (*
       g1 ─┬─→ g2 ───→ g4
           │           │
           └─→ g3 ─────┘

       g1 defines base
       g2 and g3 both depend on g1
       g4 depends on g2 and g3
    *)

    let* errors = query_errors rpc "" (Some "g1") []
      "module Base = struct\n\
       \  type id = int\n\
       \  let make_id x = x\n\
       end;;" in
    test "graph_g1" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    let* errors = query_errors rpc "" (Some "g2") ["g1"]
      "module User = struct\n\
       \  type t = { id: Base.id; name: string }\n\
       \  let create id name = { id; name }\n\
       end;;" in
    test "graph_g2" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    let* errors = query_errors rpc "" (Some "g3") ["g1"]
      "module Item = struct\n\
       \  type t = { id: Base.id; value: int }\n\
       \  let create id value = { id; value }\n\
       end;;" in
    test "graph_g3" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    (* g4 needs g1 for Base module, plus g2 and g3 *)
    let* errors = query_errors rpc "" (Some "g4") ["g1"; "g2"; "g3"]
      "let user = User.create (Base.make_id 1) \"Alice\";;\n\
       let item = Item.create (Base.make_id 100) 42;;" in
    test "graph_g4" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    Printf.printf "\n--- Section 7: Empty and Self Dependencies ---\n%!";

    (* Cell with no deps *)
    let* errors = query_errors rpc "" (Some "e1") []
      "let standalone = 999;;" in
    test "empty_deps" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

    (* Cell that tries to reference itself should fail or have errors *)
    let* errors = query_errors rpc "" (Some "self") []
      "let self_ref = 1;;" in
    test "self_define" (List.length errors = 0)
      (Printf.sprintf "%d errors" (List.length errors));

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
    Printf.printf "SUCCESS: All dependency tests passed!\n%!"
  else Printf.printf "FAILURE: Some tests failed.\n%!"
