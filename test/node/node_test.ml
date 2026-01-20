(* Unix worker *)
open Js_top_worker
open Js_top_worker_rpc.Toplevel_api_gen
open Impl

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
    (* For Node.js, we use synchronous file reading wrapped in Lwt *)
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
  (* let pid = Unix.getpid () in *)
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

let _ =
  Logs.info (fun m -> m "Starting server...");
  let rpc = start_server () in
  let ( let* ) = IdlM.ErrM.bind in
  let init_config =
    Js_top_worker_rpc.Toplevel_api_gen.
      { stdlib_dcs = None; findlib_requires = [ "base" ]; execute = true }
  in
  let x =
    let open Client in
    let* _ = init rpc init_config in
    let* o = setup rpc () in
    Logs.info (fun m ->
        m "setup output: %s" (Option.value ~default:"" o.stdout));
    let* _ = query_errors rpc (Some "c1") [] false "type xxxx = int;;\n" in
    let* o1 =
      query_errors rpc (Some "c2") [ "c1" ] false "type yyy = xxx;;\n"
    in
    Logs.info (fun m -> m "Number of errors: %d (should be 1)" (List.length o1));
    let* _ = query_errors rpc (Some "c1") [] false "type xxx = int;;\n" in
    let* o2 =
      query_errors rpc (Some "c2") [ "c1" ] false "type yyy = xxx;;\n"
    in
    Logs.info (fun m ->
        m "Number of errors1: %d (should be 1)" (List.length o1));
    Logs.info (fun m ->
        m "Number of errors2: %d (should be 0)" (List.length o2));

    (* Test completion for List.leng *)
    let* completions1 =
      let text = "let _ = List.leng" in
      Client.complete_prefix rpc (Some "c_comp1") [] false text
        (Offset (String.length text))
    in
    Logs.info (fun m ->
        m "Completions for 'List.leng': %d entries"
          (List.length completions1.entries));
    List.iter
      (fun entry ->
        Logs.info (fun m ->
            m "  - %s (%s): %s" entry.name
              (match entry.kind with
              | Constructor -> "Constructor"
              | Keyword -> "Keyword"
              | Label -> "Label"
              | MethodCall -> "MethodCall"
              | Modtype -> "Modtype"
              | Module -> "Module"
              | Type -> "Type"
              | Value -> "Value"
              | Variant -> "Variant")
              entry.desc))
      completions1.entries;

    (* Test completion for List. (should show all List module functions) *)
    let* completions2 =
      let text = "# let _ = List." in
      Client.complete_prefix rpc (Some "c_comp2") [] true text
        (Offset (String.length text))
    in
    Logs.info (fun m ->
        m "Completions for 'List.': %d entries"
          (List.length completions2.entries));
    List.iter
      (fun entry ->
        Logs.info (fun m ->
            m "  - %s (%s): %s" entry.name
              (match entry.kind with
              | Constructor -> "Constructor"
              | Keyword -> "Keyword"
              | Label -> "Label"
              | MethodCall -> "MethodCall"
              | Modtype -> "Modtype"
              | Module -> "Module"
              | Type -> "Type"
              | Value -> "Value"
              | Variant -> "Variant")
              entry.desc))
      completions2.entries;

    (* Test completion for partial identifier *)
    let* completions3 =
      let text = "# let _ = ma" in
      Client.complete_prefix rpc (Some "c_comp3") [] true text
        (Offset (String.length text))
    in
    Logs.info (fun m ->
        m "Completions for 'ma': %d entries" (List.length completions3.entries));
    List.iter
      (fun entry ->
        Logs.info (fun m ->
            m "  - %s (%s): %s" entry.name
              (match entry.kind with
              | Constructor -> "Constructor"
              | Keyword -> "Keyword"
              | Label -> "Label"
              | MethodCall -> "MethodCall"
              | Modtype -> "Modtype"
              | Module -> "Module"
              | Type -> "Type"
              | Value -> "Value"
              | Variant -> "Variant")
              entry.desc))
      completions3.entries;

    (* Test completion in non-toplevel context *)
    let* completions4 =
      let text = "let _ = List.leng" in
      Client.complete_prefix rpc (Some "c_comp4") [] false text
        (Offset (String.length text))
    in
    Logs.info (fun m ->
        m "Completions for 'List.leng' (non-toplevel): %d entries"
          (List.length completions4.entries));
    List.iter
      (fun entry ->
        Logs.info (fun m ->
            m "  - %s (%s): %s" entry.name
              (match entry.kind with
              | Constructor -> "Constructor"
              | Keyword -> "Keyword"
              | Label -> "Label"
              | MethodCall -> "MethodCall"
              | Modtype -> "Modtype"
              | Module -> "Module"
              | Type -> "Type"
              | Value -> "Value"
              | Variant -> "Variant")
              entry.desc))
      completions4.entries;

    (* Test completion using Logical position constructor *)
    let* completions5 =
      let text = "# let _ = List.leng\n   let foo=1.0;;" in
      Client.complete_prefix rpc (Some "c_comp5") [] true text
        (Logical (1, 16))
    in
    Logs.info (fun m ->
        m "Completions for 'List.leng' (Logical position): %d entries"
          (List.length completions5.entries));
    List.iter
      (fun entry ->
        Logs.info (fun m ->
            m "  - %s (%s): %s" entry.name
              (match entry.kind with
              | Constructor -> "Constructor"
              | Keyword -> "Keyword"
              | Label -> "Label"
              | MethodCall -> "MethodCall"
              | Modtype -> "Modtype"
              | Module -> "Module"
              | Type -> "Type"
              | Value -> "Value"
              | Variant -> "Variant")
              entry.desc))
      completions5.entries;

    (* Test toplevel completion with variable binding *)
    let* completions6 =
      let s = "# let my_var = 42;;\n# let x = 1 + my_v" in
      Client.complete_prefix rpc (Some "c_comp6") [] true
        s
        (Offset (String.length s))
    in
    Logs.info (fun m ->
        m "Completions for 'my_v' (toplevel variable): %d entries"
          (List.length completions6.entries));
    List.iter
      (fun entry ->
        Logs.info (fun m ->
            m "  - %s (%s): %s" entry.name
              (match entry.kind with
              | Constructor -> "Constructor"
              | Keyword -> "Keyword"
              | Label -> "Label"
              | MethodCall -> "MethodCall"
              | Modtype -> "Modtype"
              | Module -> "Module"
              | Type -> "Type"
              | Value -> "Value"
              | Variant -> "Variant")
              entry.desc))
      completions6.entries;

    (* Test toplevel completion with function definition *)
    let* completions7 =
      Client.complete_prefix rpc (Some "c_comp7") [] true
        "# let rec factorial n = if n <= 1 then 1 else n * facto"
        (Offset 55)
    in
    Logs.info (fun m ->
        m "Completions for 'facto' (recursive function): %d entries"
          (List.length completions7.entries));
    List.iter
      (fun entry ->
        Logs.info (fun m ->
            m "  - %s (%s): %s" entry.name
              (match entry.kind with
              | Constructor -> "Constructor"
              | Keyword -> "Keyword"
              | Label -> "Label"
              | MethodCall -> "MethodCall"
              | Modtype -> "Modtype"
              | Module -> "Module"
              | Type -> "Type"
              | Value -> "Value"
              | Variant -> "Variant")
              entry.desc))
      completions7.entries;

    (* Test toplevel completion with module paths *)
    let* completions8 =
      Client.complete_prefix rpc (Some "c_comp8") [] true
        "# String.lengt"
        (Offset 14)
    in
    Logs.info (fun m ->
        m "Completions for 'String.lengt' (module path): %d entries"
          (List.length completions8.entries));
    List.iter
      (fun entry ->
        Logs.info (fun m ->
            m "  - %s (%s): %s" entry.name
              (match entry.kind with
              | Constructor -> "Constructor"
              | Keyword -> "Keyword"
              | Label -> "Label"
              | MethodCall -> "MethodCall"
              | Modtype -> "Modtype"
              | Module -> "Module"
              | Type -> "Type"
              | Value -> "Value"
              | Variant -> "Variant")
              entry.desc))
      completions8.entries;

    (* let* o3 =
      Client.exec_toplevel rpc
        "# Stringext.of_list ['a';'b';'c'];;\n" in
    Logs.info (fun m -> m "Exec toplevel output: %s" o3.script); *)
    IdlM.ErrM.return ()
  in
  (* The operations are actually synchronous in this test context *)
  let promise = x |> IdlM.T.get in
  match Lwt.state promise with
  | Lwt.Return (Ok ()) -> Logs.info (fun m -> m "Success")
  | Lwt.Return (Error (InternalError s)) -> Logs.err (fun m -> m "Error: %s" s)
  | Lwt.Fail e ->
      Logs.err (fun m -> m "Unexpected failure: %s" (Printexc.to_string e))
  | Lwt.Sleep ->
      Logs.err (fun m ->
          m
            "Error: Promise is still pending (should not happen in sync \
             context)")
