(* Worker_rpc *)

open Js_top_worker_rpc

(** Functions to facilitate RPC calls to web workers. *)

exception Timeout
(** When RPC calls take too long, the Lwt promise is set to failed state with
    this exception. *)

type rpc = Rpc.call -> Rpc.response Lwt.t
(** RPC function for communicating with the worker. This is used by each RPC
    function declared in {!W} *)

val start : string -> int -> (unit -> unit) -> rpc
(** [start url timeout timeout_fn] initialises a web worker from [url] and
    starts communications with it. [timeout] is the number of seconds to wait
    for a response from any RPC before raising an error, and [timeout_fn] is
    called when a timeout occurs. Returns the {!type-rpc} function used in the
    RPC calls. *)

module W : sig
  (** {2 Type declarations}

      The following types are redeclared here for convenience. *)

  type init_config = Toplevel_api_gen.init_config
  type err = Toplevel_api_gen.err
  type exec_result = Toplevel_api_gen.exec_result

  (** {2 RPC calls}

      The first parameter of these calls is the rpc function returned by
      {!val-start}. If any of these calls fails to receive a response from the
      worker by the timeout set in the {!val-start} call, the {!Lwt} thread will
      be {{!Lwt.fail}failed}. *)

  val init : rpc -> init_config -> (unit, err) result Lwt.t
  (** Initialise the toplevel. This must be called before any other API. *)

  val create_env : rpc -> string -> (unit, err) result Lwt.t
  (** Create a new isolated execution environment with the given ID. *)

  val destroy_env : rpc -> string -> (unit, err) result Lwt.t
  (** Destroy an execution environment. *)

  val list_envs : rpc -> (string list, err) result Lwt.t
  (** List all existing environment IDs. *)

  val setup : rpc -> string -> (exec_result, err) result Lwt.t
  (** Start the toplevel for the given environment. If [env_id] is empty string,
      uses the default environment. Return value is the initial blurb printed
      when starting a toplevel. Note that the toplevel must be initialised first. *)

  val exec : rpc -> string -> string -> (exec_result, err) result Lwt.t
  (** Execute a phrase using the toplevel. If [env_id] is empty string, uses the
      default environment. The toplevel must have been initialised first. *)

  val exec_toplevel :
    rpc ->
    string ->
    string ->
    (Toplevel_api_gen.exec_toplevel_result, err) result Lwt.t
  (** Execute a toplevel script. If [env_id] is empty string, uses the default
      environment. The toplevel must have been initialised first. *)

  val query_errors :
    rpc ->
    string ->
    string option ->
    string list ->
    bool ->
    string ->
    (Toplevel_api_gen.error list, err) result Lwt.t
  (** Query the toplevel for errors. [env_id] specifies the environment. *)
end
