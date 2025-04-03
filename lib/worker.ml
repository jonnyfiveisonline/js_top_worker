open Js_top_worker_rpc
open Js_top_worker

let optbind : 'a option -> ('a -> 'b option) -> 'b option =
 fun x fn -> match x with None -> None | Some a -> fn a

let log fmt =
  Format.kasprintf
    (fun s -> Js_of_ocaml.(Console.console##log (Js.string s)))
    fmt

let sync_get url =
  let open Js_of_ocaml in
  let x = XmlHttpRequest.create () in
  x##.responseType := Js.string "arraybuffer";
  x##_open (Js.string "GET") (Js.string url) Js._false;
  x##send Js.null;
  match x##.status with
  | 200 ->
      Js.Opt.case
        (File.CoerceTo.arrayBuffer x##.response)
        (fun () ->
          Console.console##log (Js.string "Failed to receive file");
          None)
        (fun b -> Some (Typed_array.String.of_arrayBuffer b))
  | _ -> None

module Server = Toplevel_api_gen.Make (Impl.IdlM.GenServer ())

(* OCamlorg toplevel in a web worker

   This communicates with the toplevel code via the API defined in
   {!Toplevel_api}. This allows the OCaml execution to not block the "main
   thread" keeping the page responsive. *)

let server process e =
  log "Worker received: %s" e;
  let _, id, call = Jsonrpc.version_id_and_call_of_string e in
  Impl.M.bind (process call) (fun response ->
      let rtxt = Jsonrpc.string_of_response ~id response in
      log "Worker sending: %s" rtxt;
      Js_of_ocaml.Worker.post_message rtxt;
      Impl.M.return ())

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

  let sync_get = sync_get
  let create_file = Js_of_ocaml.Sys_js.create_file

  let import_scripts = Js_of_ocaml.Worker.import_scripts

  let init_function func_name =
    let open Js_of_ocaml in
    let func = Js.Unsafe.js_expr func_name in
    fun () ->
      Js.Unsafe.fun_call func [| Js.Unsafe.inject Dom_html.window |]
end

module M = Impl.Make (S)

let run () =
  (* Here we bind the server stub functions to the implementations *)
  let open Js_of_ocaml in
  let open M in
  try
    Console.console##log (Js.string "Starting worker...");

    Logs.set_reporter (Logs_browser.console_reporter ());
    Logs.set_level (Some Logs.Info);
    Server.exec execute;
    Server.setup setup;
    Server.init init;
    Server.typecheck typecheck_phrase;
    Server.complete_prefix complete_prefix;
    Server.query_errors query_errors;
    Server.type_enclosing type_enclosing;
    Server.compile_js compile_js;
    Server.exec_toplevel exec_toplevel;
    let rpc_fn = Impl.IdlM.server Server.implementation in
    Js_of_ocaml.Worker.set_onmessage (fun x -> ignore (server rpc_fn x));
    Console.console##log (Js.string "All finished")
  with e ->
    Console.console##log (Js.string ("Exception: " ^ Printexc.to_string e))
