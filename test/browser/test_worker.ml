(** Minimal test worker for browser client tests.

    This is a simplified worker that doesn't require dynamic package loading,
    making it suitable for isolated browser testing. *)

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
  type findlib_t = unit

  let capture : (unit -> 'a) -> unit -> Impl.captured * 'a =
   fun f () ->
    let stdout_buff = Buffer.create 1024 in
    let stderr_buff = Buffer.create 1024 in
    Js_of_ocaml.Sys_js.set_channel_flusher stdout (Buffer.add_string stdout_buff);
    Js_of_ocaml.Sys_js.set_channel_flusher stderr (Buffer.add_string stderr_buff);
    let x = f () in
    ({ Impl.stdout = Buffer.contents stdout_buff;
       stderr = Buffer.contents stderr_buff }, x)

  let sync_get _ = None
  let async_get _ = Lwt.return (Error (`Msg "Not implemented"))
  let create_file = Js_of_ocaml.Sys_js.create_file
  let get_stdlib_dcs _ = []
  let import_scripts _ = ()
  let findlib_init _ = Lwt.return ()
  let require _ () _ = []
  let init_function _ () = ()
  let path = "/static/cmis"
end

module M = Impl.Make (S)

let run () =
  let open Js_of_ocaml in
  let open M in
  Console.console##log (Js.string "Test worker starting...");
  Server.exec execute;
  Server.setup (Impl.IdlM.T.lift setup);
  Server.init (Impl.IdlM.T.lift init);
  Server.typecheck typecheck_phrase;
  Server.complete_prefix complete_prefix;
  Server.query_errors query_errors;
  Server.type_enclosing type_enclosing;
  Server.exec_toplevel exec_toplevel;
  let rpc_fn = Impl.IdlM.server Server.implementation in
  Worker.set_onmessage (fun x ->
      let s = Js.to_string x in
      ignore (server rpc_fn s));
  Console.console##log (Js.string "Test worker ready")

let () = run ()
