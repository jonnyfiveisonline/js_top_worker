(** Transport abstraction for RPC encoding.

    This module provides a common interface for encoding/decoding RPC messages.
    Uses JSON-RPC for browser compatibility. *)

module type S = sig
  (** Encode a call (ID is auto-generated) *)
  val string_of_call : Rpc.call -> string

  (** Decode a message to get the ID and call *)
  val id_and_call_of_string : string -> Rpc.t * Rpc.call

  (** Encode a response with the given ID *)
  val string_of_response : id:Rpc.t -> Rpc.response -> string

  (** Decode a message to get the response *)
  val response_of_string : string -> Rpc.response
end

(** JSON-RPC transport *)
module Json : S = struct
  let string_of_call call =
    Jsonrpc.string_of_call call

  let id_and_call_of_string s =
    let _, id, call = Jsonrpc.version_id_and_call_of_string s in
    (id, call)

  let string_of_response ~id response =
    Jsonrpc.string_of_response ~id response

  let response_of_string s =
    Jsonrpc.response_of_string s
end
