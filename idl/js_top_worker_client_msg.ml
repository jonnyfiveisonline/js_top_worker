(** Worker client using the message protocol.

    This client communicates with the OCaml toplevel worker using a simple
    JSON message protocol instead of RPC. *)

module Brr_worker = Brr_webworkers.Worker
module Brr_message = Brr_io.Message
module Msg = Js_top_worker_message.Message

(** Incremental output from a single phrase *)
type output_at = {
  cell_id : int;
  loc : int;  (** Character position after phrase (pos_cnum) *)
  caml_ppf : string;
  mime_vals : Msg.mime_val list;
}

(** Output result type *)
type output = {
  cell_id : int;
  stdout : string;
  stderr : string;
  caml_ppf : string;
  mime_vals : Msg.mime_val list;
}

(** Eval stream event *)
type eval_event =
  | Phrase of output_at  (** Incremental output after each phrase *)
  | Done of output       (** Final result *)
  | Error of string      (** Error occurred *)

(** Client state *)
type t = {
  worker : Brr_worker.t;
  timeout : int;
  mutable cell_id : int;
  mutable ready : bool;
  ready_waiters : (unit -> unit) Queue.t;
  pending : (int, Msg.worker_msg Lwt.u) Hashtbl.t;
  pending_env : (string, Msg.worker_msg Lwt.u) Hashtbl.t;
  pending_stream : (int, eval_event option -> unit) Hashtbl.t;
}

exception Timeout
exception InitError of string
exception EvalError of string

(** Parse a worker message from JSON string *)
let parse_worker_msg s =
  let open Js_of_ocaml in
  let obj = Json.unsafe_input (Js.string s) in
  let typ = Js.to_string (Js.Unsafe.get obj (Js.string "type")) in
  let get_int key = Js.Unsafe.get obj (Js.string key) in
  let get_string key = Js.to_string (Js.Unsafe.get obj (Js.string key)) in
  let parse_position p =
    { Msg.pos_cnum = Js.Unsafe.get p (Js.string "pos_cnum");
      pos_lnum = Js.Unsafe.get p (Js.string "pos_lnum");
      pos_bol = Js.Unsafe.get p (Js.string "pos_bol") }
  in
  let parse_location loc =
    { Msg.loc_start = parse_position (Js.Unsafe.get loc (Js.string "loc_start"));
      loc_end = parse_position (Js.Unsafe.get loc (Js.string "loc_end")) }
  in
  match typ with
  | "ready" -> Msg.Ready
  | "init_error" -> Msg.InitError { message = get_string "message" }
  | "output" ->
      let mime_vals_arr = Js.to_array (Js.Unsafe.get obj (Js.string "mime_vals")) in
      let mime_vals = Array.to_list (Array.map (fun mv ->
        { Msg.mime_type = Js.to_string (Js.Unsafe.get mv (Js.string "mime_type"));
          data = Js.to_string (Js.Unsafe.get mv (Js.string "data")) }
      ) mime_vals_arr) in
      Msg.Output {
        cell_id = get_int "cell_id";
        stdout = get_string "stdout";
        stderr = get_string "stderr";
        caml_ppf = get_string "caml_ppf";
        mime_vals;
      }
  | "completions" ->
      let c = Js.Unsafe.get obj (Js.string "completions") in
      let entries_arr = Js.to_array (Js.Unsafe.get c (Js.string "entries")) in
      let entries = Array.to_list (Array.map (fun e ->
        { Msg.name = Js.to_string (Js.Unsafe.get e (Js.string "name"));
          kind = Js.to_string (Js.Unsafe.get e (Js.string "kind"));
          desc = Js.to_string (Js.Unsafe.get e (Js.string "desc"));
          info = Js.to_string (Js.Unsafe.get e (Js.string "info"));
          deprecated = Js.to_bool (Js.Unsafe.get e (Js.string "deprecated")) }
      ) entries_arr) in
      Msg.Completions {
        cell_id = get_int "cell_id";
        completions = {
          from = Js.Unsafe.get c (Js.string "from");
          to_ = Js.Unsafe.get c (Js.string "to");
          entries;
        };
      }
  | "types" ->
      let types_arr = Js.to_array (Js.Unsafe.get obj (Js.string "types")) in
      let types = Array.to_list (Array.map (fun t ->
        { Msg.loc = parse_location (Js.Unsafe.get t (Js.string "loc"));
          type_str = Js.to_string (Js.Unsafe.get t (Js.string "type_str"));
          tail = Js.to_string (Js.Unsafe.get t (Js.string "tail")) }
      ) types_arr) in
      Msg.Types { cell_id = get_int "cell_id"; types }
  | "errors" ->
      let errors_arr = Js.to_array (Js.Unsafe.get obj (Js.string "errors")) in
      let errors = Array.to_list (Array.map (fun e ->
        let sub_arr = Js.to_array (Js.Unsafe.get e (Js.string "sub")) in
        let sub = Array.to_list (Array.map Js.to_string sub_arr) in
        { Msg.kind = Js.to_string (Js.Unsafe.get e (Js.string "kind"));
          loc = parse_location (Js.Unsafe.get e (Js.string "loc"));
          main = Js.to_string (Js.Unsafe.get e (Js.string "main"));
          sub;
          source = Js.to_string (Js.Unsafe.get e (Js.string "source")) }
      ) errors_arr) in
      Msg.ErrorList { cell_id = get_int "cell_id"; errors }
  | "eval_error" ->
      Msg.EvalError { cell_id = get_int "cell_id"; message = get_string "message" }
  | "env_created" ->
      Msg.EnvCreated { env_id = get_string "env_id" }
  | "env_destroyed" ->
      Msg.EnvDestroyed { env_id = get_string "env_id" }
  | "output_at" ->
      let mime_vals_arr = Js.to_array (Js.Unsafe.get obj (Js.string "mime_vals")) in
      let mime_vals = Array.to_list (Array.map (fun mv ->
        { Msg.mime_type = Js.to_string (Js.Unsafe.get mv (Js.string "mime_type"));
          data = Js.to_string (Js.Unsafe.get mv (Js.string "data")) }
      ) mime_vals_arr) in
      Msg.OutputAt {
        cell_id = get_int "cell_id";
        loc = get_int "loc";
        caml_ppf = get_string "caml_ppf";
        mime_vals;
      }
  | _ -> failwith ("Unknown message type: " ^ typ)

(** Handle incoming message from worker *)
let handle_message t msg =
  let data = Brr_message.Ev.data (Brr.Ev.as_type msg) in
  let parsed = parse_worker_msg (Js_of_ocaml.Js.to_string data) in
  match parsed with
  | Msg.Ready ->
      t.ready <- true;
      Queue.iter (fun f -> f ()) t.ready_waiters;
      Queue.clear t.ready_waiters
  | Msg.InitError _ ->
      t.ready <- true;
      Queue.iter (fun f -> f ()) t.ready_waiters;
      Queue.clear t.ready_waiters
  | Msg.OutputAt { cell_id; loc; caml_ppf; mime_vals } ->
      (match Hashtbl.find_opt t.pending_stream cell_id with
       | Some push -> push (Some (Phrase { cell_id; loc; caml_ppf; mime_vals }))
       | None -> ())
  | Msg.Output { cell_id; stdout; stderr; caml_ppf; mime_vals } ->
      (* Handle streaming eval *)
      (match Hashtbl.find_opt t.pending_stream cell_id with
       | Some push ->
           Hashtbl.remove t.pending_stream cell_id;
           push (Some (Done { cell_id; stdout; stderr; caml_ppf; mime_vals }));
           push None  (* Close the stream *)
       | None -> ());
      (* Handle regular eval *)
      (match Hashtbl.find_opt t.pending cell_id with
       | Some resolver ->
           Hashtbl.remove t.pending cell_id;
           Lwt.wakeup resolver parsed
       | None -> ())
  | Msg.EvalError { cell_id; message } ->
      (* Handle streaming eval *)
      (match Hashtbl.find_opt t.pending_stream cell_id with
       | Some push ->
           Hashtbl.remove t.pending_stream cell_id;
           push (Some (Error message));
           push None  (* Close the stream *)
       | None -> ());
      (* Handle regular eval *)
      (match Hashtbl.find_opt t.pending cell_id with
       | Some resolver ->
           Hashtbl.remove t.pending cell_id;
           Lwt.wakeup resolver parsed
       | None -> ())
  | Msg.Completions { cell_id; _ }
  | Msg.Types { cell_id; _ } | Msg.ErrorList { cell_id; _ } ->
      (match Hashtbl.find_opt t.pending cell_id with
       | Some resolver ->
           Hashtbl.remove t.pending cell_id;
           Lwt.wakeup resolver parsed
       | None -> ())
  | Msg.EnvCreated { env_id } | Msg.EnvDestroyed { env_id } ->
      (match Hashtbl.find_opt t.pending_env env_id with
       | Some resolver ->
           Hashtbl.remove t.pending_env env_id;
           Lwt.wakeup resolver parsed
       | None -> ())

(** Create a new worker client.
    @param timeout Timeout in milliseconds (default: 30000) *)
let create ?(timeout = 30000) url =
  let worker = Brr_worker.create (Jstr.v url) in
  let t = {
    worker;
    timeout;
    cell_id = 0;
    ready = false;
    ready_waiters = Queue.create ();
    pending = Hashtbl.create 16;
    pending_env = Hashtbl.create 16;
    pending_stream = Hashtbl.create 16;
  } in
  let _listener =
    Brr.Ev.listen Brr_message.Ev.message (handle_message t) (Brr_worker.as_target worker)
  in
  t

(** Get next cell ID *)
let next_cell_id t =
  t.cell_id <- t.cell_id + 1;
  t.cell_id

(** Send a message to the worker *)
let send t msg =
  let open Js_of_ocaml in
  let json = match msg with
    | `Init config ->
        let obj = Js.Unsafe.obj [|
          ("type", Js.Unsafe.inject (Js.string "init"));
          ("findlib_requires", Js.Unsafe.inject (Js.array (Array.of_list (List.map Js.string config.Msg.findlib_requires))));
          ("stdlib_dcs", Js.Unsafe.inject (match config.Msg.stdlib_dcs with Some s -> Js.some (Js.string s) | None -> Js.null));
          ("findlib_index", Js.Unsafe.inject (match config.Msg.findlib_index with Some s -> Js.some (Js.string s) | None -> Js.null));
        |] in
        Js.to_string (Json.output obj)
    | `Eval (cell_id, env_id, code) ->
        let obj = Js.Unsafe.obj [|
          ("type", Js.Unsafe.inject (Js.string "eval"));
          ("cell_id", Js.Unsafe.inject cell_id);
          ("env_id", Js.Unsafe.inject (Js.string env_id));
          ("code", Js.Unsafe.inject (Js.string code));
        |] in
        Js.to_string (Json.output obj)
    | `Complete (cell_id, env_id, source, position) ->
        let obj = Js.Unsafe.obj [|
          ("type", Js.Unsafe.inject (Js.string "complete"));
          ("cell_id", Js.Unsafe.inject cell_id);
          ("env_id", Js.Unsafe.inject (Js.string env_id));
          ("source", Js.Unsafe.inject (Js.string source));
          ("position", Js.Unsafe.inject position);
        |] in
        Js.to_string (Json.output obj)
    | `TypeAt (cell_id, env_id, source, position) ->
        let obj = Js.Unsafe.obj [|
          ("type", Js.Unsafe.inject (Js.string "type_at"));
          ("cell_id", Js.Unsafe.inject cell_id);
          ("env_id", Js.Unsafe.inject (Js.string env_id));
          ("source", Js.Unsafe.inject (Js.string source));
          ("position", Js.Unsafe.inject position);
        |] in
        Js.to_string (Json.output obj)
    | `Errors (cell_id, env_id, source) ->
        let obj = Js.Unsafe.obj [|
          ("type", Js.Unsafe.inject (Js.string "errors"));
          ("cell_id", Js.Unsafe.inject cell_id);
          ("env_id", Js.Unsafe.inject (Js.string env_id));
          ("source", Js.Unsafe.inject (Js.string source));
        |] in
        Js.to_string (Json.output obj)
    | `CreateEnv env_id ->
        let obj = Js.Unsafe.obj [|
          ("type", Js.Unsafe.inject (Js.string "create_env"));
          ("env_id", Js.Unsafe.inject (Js.string env_id));
        |] in
        Js.to_string (Json.output obj)
    | `DestroyEnv env_id ->
        let obj = Js.Unsafe.obj [|
          ("type", Js.Unsafe.inject (Js.string "destroy_env"));
          ("env_id", Js.Unsafe.inject (Js.string env_id));
        |] in
        Js.to_string (Json.output obj)
  in
  Brr_worker.post t.worker (Js.string json)

(** Wait for the worker to be ready *)
let wait_ready t =
  if t.ready then Lwt.return_unit
  else
    let promise, resolver = Lwt.wait () in
    Queue.push (fun () -> Lwt.wakeup resolver ()) t.ready_waiters;
    promise

(** Initialize the worker *)
let init t config =
  let open Lwt.Infix in
  send t (`Init config);
  wait_ready t >>= fun () ->
  Lwt.return_unit

(** Evaluate OCaml code *)
let eval t ?(env_id = "default") code =
  let open Lwt.Infix in
  wait_ready t >>= fun () ->
  let cell_id = next_cell_id t in
  let promise, resolver = Lwt.wait () in
  Hashtbl.add t.pending cell_id resolver;
  send t (`Eval (cell_id, env_id, code));
  promise >>= fun msg ->
  match msg with
  | Msg.Output { cell_id; stdout; stderr; caml_ppf; mime_vals } ->
      Lwt.return { cell_id; stdout; stderr; caml_ppf; mime_vals }
  | Msg.EvalError { message; _ } ->
      Lwt.fail (EvalError message)
  | _ -> Lwt.fail (Failure "Unexpected response")

(** Evaluate OCaml code with streaming output.
    Returns a stream of events: [Phrase] for each phrase as it executes,
    then [Done] with the final result, or [Error] if evaluation fails. *)
let eval_stream t ?(env_id = "default") code =
  let stream, push = Lwt_stream.create () in
  (* Wait for ready before sending, but return stream immediately *)
  Lwt.async (fun () ->
    let open Lwt.Infix in
    wait_ready t >|= fun () ->
    let cell_id = next_cell_id t in
    Hashtbl.add t.pending_stream cell_id push;
    send t (`Eval (cell_id, env_id, code)));
  stream

(** Get completions *)
let complete t ?(env_id = "default") source position =
  let open Lwt.Infix in
  wait_ready t >>= fun () ->
  let cell_id = next_cell_id t in
  let promise, resolver = Lwt.wait () in
  Hashtbl.add t.pending cell_id resolver;
  send t (`Complete (cell_id, env_id, source, position));
  promise >>= fun msg ->
  match msg with
  | Msg.Completions { completions; _ } ->
      Lwt.return completions
  | Msg.EvalError { message; _ } ->
      Lwt.fail (EvalError message)
  | _ -> Lwt.fail (Failure "Unexpected response")

(** Get type at position *)
let type_at t ?(env_id = "default") source position =
  let open Lwt.Infix in
  wait_ready t >>= fun () ->
  let cell_id = next_cell_id t in
  let promise, resolver = Lwt.wait () in
  Hashtbl.add t.pending cell_id resolver;
  send t (`TypeAt (cell_id, env_id, source, position));
  promise >>= fun msg ->
  match msg with
  | Msg.Types { types; _ } ->
      Lwt.return types
  | Msg.EvalError { message; _ } ->
      Lwt.fail (EvalError message)
  | _ -> Lwt.fail (Failure "Unexpected response")

(** Get errors *)
let errors t ?(env_id = "default") source =
  let open Lwt.Infix in
  wait_ready t >>= fun () ->
  let cell_id = next_cell_id t in
  let promise, resolver = Lwt.wait () in
  Hashtbl.add t.pending cell_id resolver;
  send t (`Errors (cell_id, env_id, source));
  promise >>= fun msg ->
  match msg with
  | Msg.ErrorList { errors; _ } ->
      Lwt.return errors
  | Msg.EvalError { message; _ } ->
      Lwt.fail (EvalError message)
  | _ -> Lwt.fail (Failure "Unexpected response")

(** Create environment *)
let create_env t env_id =
  let open Lwt.Infix in
  wait_ready t >>= fun () ->
  let promise, resolver = Lwt.wait () in
  Hashtbl.add t.pending_env env_id resolver;
  send t (`CreateEnv env_id);
  promise >>= fun msg ->
  match msg with
  | Msg.EnvCreated _ -> Lwt.return_unit
  | Msg.InitError { message } -> Lwt.fail (InitError message)
  | _ -> Lwt.fail (Failure "Unexpected response")

(** Destroy environment *)
let destroy_env t env_id =
  let open Lwt.Infix in
  wait_ready t >>= fun () ->
  let promise, resolver = Lwt.wait () in
  Hashtbl.add t.pending_env env_id resolver;
  send t (`DestroyEnv env_id);
  promise >>= fun msg ->
  match msg with
  | Msg.EnvDestroyed _ -> Lwt.return_unit
  | Msg.InitError { message } -> Lwt.fail (InitError message)
  | _ -> Lwt.fail (Failure "Unexpected response")

(** Terminate the worker *)
let terminate t =
  Brr_worker.terminate t.worker
