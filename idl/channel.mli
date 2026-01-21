(** Bidirectional message channel for worker communication.

    This module extends the RPC model to support push messages from
    server to client, enabling:
    - Streaming output (stdout/stderr)
    - Widget state updates
    - Progress notifications

    Message types:
    - Request: client → server (expects response)
    - Response: server → client (matches request ID)
    - Push: server → client (one-way notification)
    - Event: client → server (widget interactions, no response)
*)

(** {1 Message Types} *)

type push_kind =
  | Output of { stream : [ `Stdout | `Stderr ]; data : string }
  | Widget_update of { widget_id : string; state : Rpc.t }
  | Progress of { task_id : string; percent : int; message : string option }
  | Custom_push of { kind : string; data : Rpc.t }
(** Types of push messages from server to client. *)

type event_kind =
  | Widget_event of { widget_id : string; event_type : string; data : Rpc.t }
  | Custom_event of { kind : string; data : Rpc.t }
(** Types of event messages from client to server. *)

type message =
  | Request of { id : int64; call : Rpc.call }
  | Response of { id : int64; response : Rpc.response }
  | Push of push_kind
  | Event of event_kind
(** A message in the channel protocol. *)

(** {1 Encoding/Decoding} *)

val encode : message -> string
(** [encode msg] encodes a message to CBOR. *)

val decode : string -> (message, string) result
(** [decode s] decodes a CBOR message. *)

val decode_exn : string -> message
(** [decode_exn s] decodes a CBOR message, raising on error. *)

(** {1 Convenience Functions} *)

val encode_request : int64 -> Rpc.call -> string
(** [encode_request id call] encodes an RPC request. *)

val encode_response : int64 -> Rpc.response -> string
(** [encode_response id response] encodes an RPC response. *)

val encode_push : push_kind -> string
(** [encode_push kind] encodes a push notification. *)

val encode_event : event_kind -> string
(** [encode_event kind] encodes a client event. *)

(** {1 Push Message Helpers} *)

val push_stdout : string -> string
(** [push_stdout data] creates an encoded stdout push message. *)

val push_stderr : string -> string
(** [push_stderr data] creates an encoded stderr push message. *)

val push_widget_update : widget_id:string -> Rpc.t -> string
(** [push_widget_update ~widget_id state] creates a widget update message. *)

val push_progress : task_id:string -> percent:int -> ?message:string -> unit -> string
(** [push_progress ~task_id ~percent ?message ()] creates a progress message. *)
