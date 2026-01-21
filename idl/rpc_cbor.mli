(** CBOR encoding for Rpc.t values.

    This module provides encoding and decoding of [Rpc.t] values to/from
    CBOR format, allowing ocaml-rpc to use CBOR as a wire format instead
    of JSON or XML. *)

val codec : Rpc.t Cbort.t
(** Codec for [Rpc.t] values. Can be used with [Cbort.encode_string]
    and [Cbort.decode_string]. *)

val encode : Rpc.t -> string
(** [encode v] encodes an [Rpc.t] value to a CBOR byte string. *)

val decode : string -> (Rpc.t, Cbort.Error.t) result
(** [decode s] decodes a CBOR byte string to an [Rpc.t] value. *)

val decode_exn : string -> Rpc.t
(** [decode_exn s] is like [decode] but raises on error. *)

(** {1 RPC Call Encoding}

    Convenience functions for encoding/decoding RPC calls and responses. *)

val call_codec : Rpc.call Cbort.t
(** Codec for RPC calls. *)

val response_codec : Rpc.response Cbort.t
(** Codec for RPC responses. *)

val encode_call : Rpc.call -> string
(** [encode_call c] encodes an RPC call to CBOR. *)

val decode_call : string -> (Rpc.call, Cbort.Error.t) result
(** [decode_call s] decodes a CBOR byte string to an RPC call. *)

val encode_response : Rpc.response -> string
(** [encode_response r] encodes an RPC response to CBOR. *)

val decode_response : string -> (Rpc.response, Cbort.Error.t) result
(** [decode_response s] decodes a CBOR byte string to an RPC response. *)

(** {1 Message Envelope Encoding}

    These types and functions handle protocol-level encoding that includes
    request IDs for matching requests with responses. *)

type request = {
  id : Rpc.t;
  call : Rpc.call;
}
(** A request message envelope containing the request ID and call. *)

type response_msg = {
  id : Rpc.t;
  response : Rpc.response;
}
(** A response message envelope containing the request ID and response. *)

val encode_request : request -> string
(** [encode_request r] encodes a request envelope to CBOR. *)

val decode_request : string -> (request, Cbort.Error.t) result
(** [decode_request s] decodes a CBOR byte string to a request envelope. *)

val encode_response_msg : response_msg -> string
(** [encode_response_msg r] encodes a response envelope to CBOR. *)

val decode_response_msg : string -> (response_msg, Cbort.Error.t) result
(** [decode_response_msg s] decodes a CBOR byte string to a response envelope. *)

(** {1 Jsonrpc-compatible API}

    These functions match the Jsonrpc module's API for easy drop-in replacement. *)

val string_of_call : ?id:Rpc.t -> Rpc.call -> string
(** [string_of_call ~id call] encodes a call with the given ID to CBOR.
    If [id] is not provided, defaults to [Rpc.Int 0L]. *)

val id_and_call_of_string : string -> Rpc.t * Rpc.call
(** [id_and_call_of_string s] decodes a CBOR request and returns the ID and call.
    @raise Failure if decoding fails. *)

val string_of_response : id:Rpc.t -> Rpc.response -> string
(** [string_of_response ~id response] encodes a response with the given ID to CBOR. *)

val response_of_string : string -> Rpc.response
(** [response_of_string s] decodes a CBOR response message and returns the response.
    @raise Failure if decoding fails. *)
