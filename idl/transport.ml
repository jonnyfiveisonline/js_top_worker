(** Transport abstraction for RPC encoding.

    This module provides a common interface for encoding/decoding RPC messages,
    allowing switching between JSON and CBOR transports. *)

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

(* Counter for generating unique request IDs *)
let cbor_id_counter = ref 0L

let new_cbor_id () =
  cbor_id_counter := Int64.add 1L !cbor_id_counter;
  !cbor_id_counter

(** JSON-RPC transport (existing protocol) *)
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

(** CBOR transport (compact binary protocol) *)
module Cbor : S = struct
  let string_of_call call =
    let id = Rpc.Int (new_cbor_id ()) in
    Rpc_cbor.string_of_call ~id call

  let id_and_call_of_string = Rpc_cbor.id_and_call_of_string
  let string_of_response = Rpc_cbor.string_of_response
  let response_of_string = Rpc_cbor.response_of_string
end

(** Auto-detecting transport that decodes based on message format *)
module Auto : S = struct
  (* CBOR messages start with specific byte patterns based on major type.
     JSON messages typically start with '{' (0x7B).
     Since CBOR uses major types 0-7 in the high 3 bits, the first byte
     for a CBOR map (what we encode) would be 0xA0-0xBF (major type 5).
     JSON '{' is 0x7B which is different from any CBOR map prefix. *)

  let is_json s =
    String.length s > 0 && s.[0] = '{'

  let string_of_call call =
    let id = Rpc.Int (new_cbor_id ()) in
    Rpc_cbor.string_of_call ~id call

  let id_and_call_of_string = Rpc_cbor.id_and_call_of_string
  let string_of_response = Rpc_cbor.string_of_response

  let response_of_string s =
    if is_json s then
      Json.response_of_string s
    else
      Rpc_cbor.response_of_string s
end
