open Js_top_worker_rpc
open Js_top_worker

(* OCamlorg toplevel in a web worker

   This communicates with the toplevel code via a simple message-based
   protocol defined in {!Js_top_worker_message.Message}. This allows
   the OCaml execution to not block the "main thread" keeping the page
   responsive. *)

module Msg = Js_top_worker_message.Message

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

(** Send a message back to the client *)
let send_message msg =
  let json = Msg.string_of_worker_msg msg in
  Jslib.log "Worker sending: %s" json;
  Js_of_ocaml.Worker.post_message (Js_of_ocaml.Js.string json)

(** Convert exec_result to Message.Output *)
let output_of_exec_result cell_id (r : Toplevel_api_gen.exec_result) =
  let mime_vals = List.map (fun (mv : Toplevel_api_gen.mime_val) ->
    { Msg.mime_type = mv.mime_type; data = mv.data }
  ) r.mime_vals in
  Msg.Output {
    cell_id;
    stdout = Option.value ~default:"" r.stdout;
    stderr = Option.value ~default:"" r.stderr;
    caml_ppf = Option.value ~default:"" r.caml_ppf;
    mime_vals;
  }

(** Convert completions to Message.Completions *)
let completions_of_result cell_id (c : Toplevel_api_gen.completions) =
  let entries = List.map (fun (e : Toplevel_api_gen.query_protocol_compl_entry) ->
    let kind = match e.kind with
      | Constructor -> "Constructor"
      | Keyword -> "Keyword"
      | Label -> "Label"
      | MethodCall -> "MethodCall"
      | Modtype -> "Modtype"
      | Module -> "Module"
      | Type -> "Type"
      | Value -> "Value"
      | Variant -> "Variant"
    in
    { Msg.name = e.name; kind; desc = e.desc; info = e.info; deprecated = e.deprecated }
  ) c.entries in
  Msg.Completions {
    cell_id;
    completions = { from = c.from; to_ = c.to_; entries };
  }

(** Convert location to Message.location *)
let location_of_loc (loc : Toplevel_api_gen.location) : Msg.location =
  {
    loc_start = {
      pos_cnum = loc.loc_start.pos_cnum;
      pos_lnum = loc.loc_start.pos_lnum;
      pos_bol = loc.loc_start.pos_bol;
    };
    loc_end = {
      pos_cnum = loc.loc_end.pos_cnum;
      pos_lnum = loc.loc_end.pos_lnum;
      pos_bol = loc.loc_end.pos_bol;
    };
  }

(** Convert error_kind to string *)
let string_of_error_kind = function
  | Toplevel_api_gen.Report_error -> "error"
  | Report_warning s -> "warning:" ^ s
  | Report_warning_as_error s -> "warning_as_error:" ^ s
  | Report_alert s -> "alert:" ^ s
  | Report_alert_as_error s -> "alert_as_error:" ^ s

(** Convert error_source to string *)
let string_of_error_source = function
  | Toplevel_api_gen.Lexer -> "lexer"
  | Parser -> "parser"
  | Typer -> "typer"
  | Warning -> "warning"
  | Unknown -> "unknown"
  | Env -> "env"
  | Config -> "config"

(** Convert errors to Message.ErrorList *)
let errors_of_result cell_id (errors : Toplevel_api_gen.error list) =
  let errors = List.map (fun (e : Toplevel_api_gen.error) ->
    {
      Msg.kind = string_of_error_kind e.kind;
      loc = location_of_loc e.loc;
      main = e.main;
      sub = e.sub;
      source = string_of_error_source e.source;
    }
  ) errors in
  Msg.ErrorList { cell_id; errors }

(** Convert typed_enclosings to Message.Types *)
let types_of_result cell_id (enclosings : Toplevel_api_gen.typed_enclosings list) =
  let types = List.map (fun ((loc, idx_or_str, tail) : Toplevel_api_gen.typed_enclosings) ->
    let type_str = match idx_or_str with
      | Toplevel_api_gen.String s -> s
      | Index _ -> ""
    in
    let tail = match tail with
      | Toplevel_api_gen.No -> "no"
      | Tail_position -> "tail_position"
      | Tail_call -> "tail_call"
    in
    {
      Msg.loc = location_of_loc loc;
      type_str;
      tail;
    }
  ) enclosings in
  Msg.Types { cell_id; types }

(** Convert position from int to Toplevel_api_gen.msource_position *)
let position_of_int pos =
  Toplevel_api_gen.Offset pos

(** Handle a client message *)
let handle_message msg =
  let open Lwt.Infix in
  match msg with
  | Msg.Init config ->
      let init_config : Toplevel_api_gen.init_config = {
        findlib_requires = config.findlib_requires;
        stdlib_dcs = config.stdlib_dcs;
        findlib_index = config.findlib_index;
        execute = true;
      } in
      M.init init_config >>= fun result ->
      (match result with
       | Ok () ->
           (* After init, automatically setup the default environment *)
           M.setup "" >|= fun setup_result ->
           (match setup_result with
            | Ok _ -> send_message Msg.Ready
            | Error (Toplevel_api_gen.InternalError msg) ->
                send_message (Msg.InitError { message = msg }))
       | Error (Toplevel_api_gen.InternalError msg) ->
           send_message (Msg.InitError { message = msg });
           Lwt.return_unit)

  | Msg.Eval { cell_id; env_id; code } ->
      Jslib.log "Eval cell_id=%d env_id=%s" cell_id env_id;
      Rpc_lwt.T.get (M.execute env_id code) >|= fun result ->
      (match result with
       | Ok exec_result ->
           send_message (output_of_exec_result cell_id exec_result)
       | Error (Toplevel_api_gen.InternalError msg) ->
           send_message (Msg.EvalError { cell_id; message = msg }))

  | Msg.Complete { cell_id; env_id; source; position } ->
      let pos = position_of_int position in
      Rpc_lwt.T.get (M.complete_prefix env_id None [] false source pos) >|= fun result ->
      (match result with
       | Ok completions ->
           send_message (completions_of_result cell_id completions)
       | Error (Toplevel_api_gen.InternalError msg) ->
           send_message (Msg.EvalError { cell_id; message = msg }))

  | Msg.TypeAt { cell_id; env_id; source; position } ->
      let pos = position_of_int position in
      Rpc_lwt.T.get (M.type_enclosing env_id None [] false source pos) >|= fun result ->
      (match result with
       | Ok types ->
           send_message (types_of_result cell_id types)
       | Error (Toplevel_api_gen.InternalError msg) ->
           send_message (Msg.EvalError { cell_id; message = msg }))

  | Msg.Errors { cell_id; env_id; source } ->
      Rpc_lwt.T.get (M.query_errors env_id None [] false source) >|= fun result ->
      (match result with
       | Ok errors ->
           send_message (errors_of_result cell_id errors)
       | Error (Toplevel_api_gen.InternalError msg) ->
           send_message (Msg.EvalError { cell_id; message = msg }))

  | Msg.CreateEnv { env_id } ->
      M.create_env env_id >|= fun result ->
      (match result with
       | Ok () -> send_message (Msg.EnvCreated { env_id })
       | Error (Toplevel_api_gen.InternalError msg) ->
           send_message (Msg.InitError { message = msg }))

  | Msg.DestroyEnv { env_id } ->
      M.destroy_env env_id >|= fun result ->
      (match result with
       | Ok () -> send_message (Msg.EnvDestroyed { env_id })
       | Error (Toplevel_api_gen.InternalError msg) ->
           send_message (Msg.InitError { message = msg }))

let run () =
  let open Js_of_ocaml in
  try
    Console.console##log (Js.string "Starting worker (message protocol)...");

    Logs.set_reporter (Logs_browser.console_reporter ());
    Logs.set_level (Some Logs.Debug);

    Js_of_ocaml.Worker.set_onmessage (fun x ->
        let s = Js_of_ocaml.Js.to_string x in
        Jslib.log "Worker received: %s" s;
        try
          let msg = Msg.client_msg_of_string s in
          Lwt.async (fun () -> handle_message msg)
        with e ->
          Jslib.log "Error parsing message: %s" (Printexc.to_string e);
          send_message (Msg.InitError { message = Printexc.to_string e }));

    Console.console##log (Js.string "Worker ready")
  with e ->
    Console.console##log (Js.string ("Exception: " ^ Printexc.to_string e))
