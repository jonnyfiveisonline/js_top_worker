(** Full-featured JSON-RPC worker for x-ocaml integration.

    Uses the same full S module as worker.ml (with Findlibish, sync/async
    get, etc.) but speaks JSON-RPC instead of the message protocol. *)

open Js_top_worker_rpc
open Js_top_worker
module Server = Toplevel_api_gen.Make (Impl.IdlM.GenServer ())

let server process e =
  let _, id, call = Jsonrpc.version_id_and_call_of_string e in
  Lwt.bind (process call) (fun response ->
      let rtxt = Jsonrpc.string_of_response ~id response in
      Js_of_ocaml.Worker.post_message (Js_of_ocaml.Js.string rtxt);
      Lwt.return ())

module S : Impl.S = struct
  type findlib_t = Js_top_worker_web.Findlibish.t

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

  let sync_get = Js_top_worker_web.Jslib.sync_get
  let async_get = Js_top_worker_web.Jslib.async_get

  let create_file ~name ~content =
    try Js_of_ocaml.Sys_js.create_file ~name ~content
    with Sys_error _ -> ()

  let get_stdlib_dcs uri =
    Js_top_worker_web.Findlibish.fetch_dynamic_cmis sync_get uri
    |> Result.to_list

  let import_scripts urls =
    let absolute_urls = List.map Js_top_worker_web.Jslib.map_url urls in
    Js_of_ocaml.Worker.import_scripts absolute_urls

  let findlib_init = Js_top_worker_web.Findlibish.init async_get

  let require b v = function
    | [] -> []
    | packages ->
        Js_top_worker_web.Findlibish.require ~import_scripts sync_get b v
          packages

  let init_function func_name =
    let open Js_of_ocaml in
    let func = Js.Unsafe.js_expr func_name in
    fun () -> Js.Unsafe.fun_call func [| Js.Unsafe.inject Dom_html.window |]

  let path = "/static/cmis"
end

module M = Impl.Make (S)

let run () =
  let open Js_of_ocaml in
  let open M in
  Console.console##log (Js.string "RPC worker starting...");
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
  Worker.set_onmessage (fun x ->
      let s = Js.to_string x in
      ignore (server rpc_fn s));
  Console.console##log (Js.string "RPC worker ready")

let () = run ()
