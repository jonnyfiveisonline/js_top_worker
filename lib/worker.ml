open Js_top_worker_rpc
open Js_top_worker
module Server = Toplevel_api_gen.Make (Impl.IdlM.GenServer ())

(* OCamlorg toplevel in a web worker

   This communicates with the toplevel code via the API defined in
   {!Toplevel_api}. This allows the OCaml execution to not block the "main
   thread" keeping the page responsive. *)

let server process e =
  let id, call = Transport.Json.id_and_call_of_string e in
  Lwt.bind (process call) (fun response ->
      let rtxt = Transport.Json.string_of_response ~id response in
      Js_of_ocaml.Worker.post_message (Js_of_ocaml.Js.string rtxt);
      Lwt.return ())

let loc = function
  | Syntaxerr.Error x -> Some (Syntaxerr.location_of_error x)
  | Lexer.Error (_, loc)
  | Typecore.Error (loc, _, _)
  | Typetexp.Error (loc, _, _)
  | Typeclass.Error (loc, _, _)
  | Typemod.Error (loc, _, _)
  | Typedecl.Error (loc, _)
  | Translcore.Error (loc, _)
  | Translclass.Error (loc, _)
  | Translmod.Error (loc, _) ->
      Some loc
  | _ -> None

module S : Impl.S = struct
  type findlib_t = Findlibish.t

  let capture : (unit -> 'a) -> unit -> Impl.captured * 'a =
   fun f () ->
    let stdout_buff = Buffer.create 1024 in
    let stderr_buff = Buffer.create 1024 in
    Js_of_ocaml.Sys_js.set_channel_flusher stdout
      (Buffer.add_string stdout_buff);
    Js_of_ocaml.Sys_js.set_channel_flusher stderr
      (Buffer.add_string stderr_buff);
    let x = f () in
    let captured =
      {
        Impl.stdout = Buffer.contents stdout_buff;
        stderr = Buffer.contents stderr_buff;
      }
    in
    (captured, x)

  let sync_get = Jslib.sync_get
  let async_get = Jslib.async_get

  (* Idempotent create_file that ignores "file already exists" errors.
     This is needed because multiple .cma.js files compiled with --toplevel
     may embed the same CMI files, and when loaded via import_scripts they
     all try to register those CMIs. *)
  let create_file ~name ~content =
    try Js_of_ocaml.Sys_js.create_file ~name ~content
    with Sys_error _ -> ()

  let get_stdlib_dcs uri =
    Findlibish.fetch_dynamic_cmis sync_get uri |> Result.to_list

  let import_scripts urls =
    (* Map relative URLs to absolute using the global base URL *)
    let absolute_urls = List.map Jslib.map_url urls in
    Js_of_ocaml.Worker.import_scripts absolute_urls
  let findlib_init = Findlibish.init async_get

  let require b v = function
    | [] -> []
    | packages -> Findlibish.require ~import_scripts sync_get b v packages

  let init_function func_name =
    let open Js_of_ocaml in
    let func = Js.Unsafe.js_expr func_name in
    fun () -> Js.Unsafe.fun_call func [| Js.Unsafe.inject Dom_html.window |]

  let path = "/static/cmis"
end

module M = Impl.Make (S)

let test () =
  let oc = open_out "/tmp/mytest.txt" in
  Printf.fprintf oc "Hello, world\n%!";
  close_out oc

let run () =
  (* Here we bind the server stub functions to the implementations *)
  let open Js_of_ocaml in
  let open M in
  try
    Console.console##log (Js.string "Starting worker...");

    let _ = test () in
    Logs.set_reporter (Logs_browser.console_reporter ());
    Logs.set_level (Some Logs.Debug);
    Server.init (Impl.IdlM.T.lift init);
    Server.create_env (Impl.IdlM.T.lift create_env);
    Server.destroy_env (Impl.IdlM.T.lift destroy_env);
    Server.list_envs (Impl.IdlM.T.lift list_envs);
    Server.setup (Impl.IdlM.T.lift setup);
    Server.exec execute;
    Server.complete_prefix complete_prefix;
    Server.query_errors query_errors;
    Server.type_enclosing type_enclosing;
    Server.exec_toplevel exec_toplevel;
    let rpc_fn = Impl.IdlM.server Server.implementation in
    Js_of_ocaml.Worker.set_onmessage (fun x ->
        let s = Js_of_ocaml.Js.to_string x in
        Jslib.log "Worker received: %s" s;
        Lwt.async (fun () -> server rpc_fn s));
    Console.console##log (Js.string "All finished")
  with e ->
    Console.console##log (Js.string ("Exception: " ^ Printexc.to_string e))
