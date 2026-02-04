(** Message protocol for worker communication.

    This module defines a simple JSON-based message protocol for communication
    between the client and the OCaml toplevel worker. *)

open Js_of_ocaml

(** {1 Types} *)

type mime_val = {
  mime_type : string;
  data : string;
}

type position = {
  pos_cnum : int;
  pos_lnum : int;
  pos_bol : int;
}

type location = {
  loc_start : position;
  loc_end : position;
}

type compl_entry = {
  name : string;
  kind : string;
  desc : string;
  info : string;
  deprecated : bool;
}

type completions = {
  from : int;
  to_ : int;
  entries : compl_entry list;
}

type error = {
  kind : string;
  loc : location;
  main : string;
  sub : string list;
  source : string;
}

type type_info = {
  loc : location;
  type_str : string;
  tail : string;
}

type init_config = {
  findlib_requires : string list;
  stdlib_dcs : string option;
  findlib_index : string option;
}

(** {1 Client -> Worker messages} *)

type client_msg =
  | Init of init_config
  | Eval of { cell_id : int; env_id : string; code : string }
  | Complete of { cell_id : int; env_id : string; source : string; position : int }
  | TypeAt of { cell_id : int; env_id : string; source : string; position : int }
  | Errors of { cell_id : int; env_id : string; source : string }
  | CreateEnv of { env_id : string }
  | DestroyEnv of { env_id : string }

(** {1 Worker -> Client messages} *)

type worker_msg =
  | Ready
  | InitError of { message : string }
  | Output of {
      cell_id : int;
      stdout : string;
      stderr : string;
      caml_ppf : string;
      mime_vals : mime_val list;
    }
  | Completions of { cell_id : int; completions : completions }
  | Types of { cell_id : int; types : type_info list }
  | ErrorList of { cell_id : int; errors : error list }
  | EvalError of { cell_id : int; message : string }
  | EnvCreated of { env_id : string }
  | EnvDestroyed of { env_id : string }

(** {1 JSON helpers} *)

let json_of_obj pairs =
  Js.Unsafe.obj (Array.of_list (List.map (fun (k, v) -> (k, Js.Unsafe.inject v)) pairs))

let json_string s = Js.Unsafe.inject (Js.string s)
let json_int n = Js.Unsafe.inject n
let json_bool b = Js.Unsafe.inject (Js.bool b)

let json_array arr =
  Js.Unsafe.inject (Js.array (Array.of_list arr))

let get_string obj key =
  Js.to_string (Js.Unsafe.get obj (Js.string key))

let get_int obj key =
  Js.Unsafe.get obj (Js.string key)

let get_string_opt obj key =
  let v : Js.js_string Js.t Js.Optdef.t = Js.Unsafe.get obj (Js.string key) in
  Js.Optdef.to_option v |> Option.map Js.to_string

let get_array obj key =
  Js.to_array (Js.Unsafe.get obj (Js.string key))

let get_string_array obj key =
  Array.to_list (Array.map Js.to_string (get_array obj key))

(** {1 Worker message serialization} *)

let json_of_position p =
  json_of_obj [
    ("pos_cnum", json_int p.pos_cnum);
    ("pos_lnum", json_int p.pos_lnum);
    ("pos_bol", json_int p.pos_bol);
  ]

let json_of_location loc =
  json_of_obj [
    ("loc_start", Js.Unsafe.inject (json_of_position loc.loc_start));
    ("loc_end", Js.Unsafe.inject (json_of_position loc.loc_end));
  ]

let json_of_mime_val mv =
  json_of_obj [
    ("mime_type", json_string mv.mime_type);
    ("data", json_string mv.data);
  ]

let json_of_compl_entry e =
  json_of_obj [
    ("name", json_string e.name);
    ("kind", json_string e.kind);
    ("desc", json_string e.desc);
    ("info", json_string e.info);
    ("deprecated", json_bool e.deprecated);
  ]

let json_of_completions c =
  json_of_obj [
    ("from", json_int c.from);
    ("to", json_int c.to_);
    ("entries", json_array (List.map (fun e -> Js.Unsafe.inject (json_of_compl_entry e)) c.entries));
  ]

let json_of_error e =
  json_of_obj [
    ("kind", json_string e.kind);
    ("loc", Js.Unsafe.inject (json_of_location e.loc));
    ("main", json_string e.main);
    ("sub", json_array (List.map json_string e.sub));
    ("source", json_string e.source);
  ]

let json_of_type_info t =
  json_of_obj [
    ("loc", Js.Unsafe.inject (json_of_location t.loc));
    ("type_str", json_string t.type_str);
    ("tail", json_string t.tail);
  ]

let json_of_worker_msg msg =
  let obj = match msg with
    | Ready ->
        json_of_obj [("type", json_string "ready")]
    | InitError { message } ->
        json_of_obj [
          ("type", json_string "init_error");
          ("message", json_string message);
        ]
    | Output { cell_id; stdout; stderr; caml_ppf; mime_vals } ->
        json_of_obj [
          ("type", json_string "output");
          ("cell_id", json_int cell_id);
          ("stdout", json_string stdout);
          ("stderr", json_string stderr);
          ("caml_ppf", json_string caml_ppf);
          ("mime_vals", json_array (List.map (fun mv -> Js.Unsafe.inject (json_of_mime_val mv)) mime_vals));
        ]
    | Completions { cell_id; completions } ->
        json_of_obj [
          ("type", json_string "completions");
          ("cell_id", json_int cell_id);
          ("completions", Js.Unsafe.inject (json_of_completions completions));
        ]
    | Types { cell_id; types } ->
        json_of_obj [
          ("type", json_string "types");
          ("cell_id", json_int cell_id);
          ("types", json_array (List.map (fun t -> Js.Unsafe.inject (json_of_type_info t)) types));
        ]
    | ErrorList { cell_id; errors } ->
        json_of_obj [
          ("type", json_string "errors");
          ("cell_id", json_int cell_id);
          ("errors", json_array (List.map (fun e -> Js.Unsafe.inject (json_of_error e)) errors));
        ]
    | EvalError { cell_id; message } ->
        json_of_obj [
          ("type", json_string "eval_error");
          ("cell_id", json_int cell_id);
          ("message", json_string message);
        ]
    | EnvCreated { env_id } ->
        json_of_obj [
          ("type", json_string "env_created");
          ("env_id", json_string env_id);
        ]
    | EnvDestroyed { env_id } ->
        json_of_obj [
          ("type", json_string "env_destroyed");
          ("env_id", json_string env_id);
        ]
  in
  Js.to_string (Json.output obj)

(** {1 Client message parsing} *)

let parse_init_config obj =
  {
    findlib_requires = get_string_array obj "findlib_requires";
    stdlib_dcs = get_string_opt obj "stdlib_dcs";
    findlib_index = get_string_opt obj "findlib_index";
  }

let client_msg_of_string s =
  let obj = Json.unsafe_input (Js.string s) in
  let typ = get_string obj "type" in
  match typ with
  | "init" ->
      Init (parse_init_config obj)
  | "eval" ->
      Eval {
        cell_id = get_int obj "cell_id";
        env_id = get_string obj "env_id";
        code = get_string obj "code";
      }
  | "complete" ->
      Complete {
        cell_id = get_int obj "cell_id";
        env_id = get_string obj "env_id";
        source = get_string obj "source";
        position = get_int obj "position";
      }
  | "type_at" ->
      TypeAt {
        cell_id = get_int obj "cell_id";
        env_id = get_string obj "env_id";
        source = get_string obj "source";
        position = get_int obj "position";
      }
  | "errors" ->
      Errors {
        cell_id = get_int obj "cell_id";
        env_id = get_string obj "env_id";
        source = get_string obj "source";
      }
  | "create_env" ->
      CreateEnv { env_id = get_string obj "env_id" }
  | "destroy_env" ->
      DestroyEnv { env_id = get_string obj "env_id" }
  | _ ->
      failwith ("Unknown message type: " ^ typ)

let string_of_worker_msg = json_of_worker_msg
