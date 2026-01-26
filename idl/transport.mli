(** Transport abstraction for RPC encoding.

    This module provides a common interface for encoding/decoding RPC messages.
    Uses JSON-RPC for browser compatibility. *)

(** Transport signature defining the encoding/decoding interface. *)
module type S = sig
  val string_of_call : Rpc.call -> string
  (** Encode a call. A unique request ID is auto-generated. *)

  val id_and_call_of_string : string -> Rpc.t * Rpc.call
  (** Decode a message to get the ID and call.
      @raise Failure if decoding fails. *)

  val string_of_response : id:Rpc.t -> Rpc.response -> string
  (** Encode a response with the given ID. *)

  val response_of_string : string -> Rpc.response
  (** Decode a message to get the response.
      @raise Failure if decoding fails. *)
end

(** JSON-RPC transport.
    Uses the standard JSON-RPC 2.0 encoding from [rpclib.json]. *)
module Json : S
