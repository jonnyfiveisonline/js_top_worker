(** Bidirectional message channel for worker communication. *)

type push_kind =
  | Output of { stream : [ `Stdout | `Stderr ]; data : string }
  | Widget_update of { widget_id : string; state : Rpc.t }
  | Progress of { task_id : string; percent : int; message : string option }
  | Custom_push of { kind : string; data : Rpc.t }

type event_kind =
  | Widget_event of { widget_id : string; event_type : string; data : Rpc.t }
  | Custom_event of { kind : string; data : Rpc.t }

type message =
  | Request of { id : int64; call : Rpc.call }
  | Response of { id : int64; response : Rpc.response }
  | Push of push_kind
  | Event of event_kind

(* CBOR tags for message discrimination *)
let tag_request = 0
let tag_response = 1
let tag_push = 2
let tag_event = 3

(* CBOR tags for push kinds *)
let push_tag_output = 0
let push_tag_widget_update = 1
let push_tag_progress = 2
let push_tag_custom = 3

(* CBOR tags for event kinds *)
let event_tag_widget_event = 0
let event_tag_custom = 1

(* Stream tags *)
let stream_stdout = 0
let stream_stderr = 1

(* Codecs for push_kind *)
let push_kind_codec : push_kind Cbort.t =
  let open Cbort in
  let case_output =
    Variant.case push_tag_output
      (tuple2 int string)
      (fun (stream_int, data) ->
        let stream = if stream_int = stream_stdout then `Stdout else `Stderr in
        Output { stream; data })
      (function
        | Output { stream; data } ->
            let stream_int = match stream with `Stdout -> stream_stdout | `Stderr -> stream_stderr in
            Some (stream_int, data)
        | _ -> None)
  in
  let case_widget_update =
    Variant.case push_tag_widget_update
      (tuple2 string Rpc_cbor.codec)
      (fun (widget_id, state) -> Widget_update { widget_id; state })
      (function
        | Widget_update { widget_id; state } -> Some (widget_id, state)
        | _ -> None)
  in
  let case_progress =
    Variant.case push_tag_progress
      (tuple3 string int (nullable string))
      (fun (task_id, percent, message) -> Progress { task_id; percent; message })
      (function
        | Progress { task_id; percent; message } -> Some (task_id, percent, message)
        | _ -> None)
  in
  let case_custom =
    Variant.case push_tag_custom
      (tuple2 string Rpc_cbor.codec)
      (fun (kind, data) -> Custom_push { kind; data })
      (function
        | Custom_push { kind; data } -> Some (kind, data)
        | _ -> None)
  in
  Variant.variant [ case_output; case_widget_update; case_progress; case_custom ]

(* Codecs for event_kind *)
let event_kind_codec : event_kind Cbort.t =
  let open Cbort in
  let case_widget_event =
    Variant.case event_tag_widget_event
      (tuple3 string string Rpc_cbor.codec)
      (fun (widget_id, event_type, data) -> Widget_event { widget_id; event_type; data })
      (function
        | Widget_event { widget_id; event_type; data } -> Some (widget_id, event_type, data)
        | _ -> None)
  in
  let case_custom =
    Variant.case event_tag_custom
      (tuple2 string Rpc_cbor.codec)
      (fun (kind, data) -> Custom_event { kind; data })
      (function
        | Custom_event { kind; data } -> Some (kind, data)
        | _ -> None)
  in
  Variant.variant [ case_widget_event; case_custom ]

(* Main message codec *)
let message_codec : message Cbort.t =
  let open Cbort in
  let case_request =
    Variant.case tag_request
      (tuple2 int64 Rpc_cbor.call_codec)
      (fun (id, call) -> Request { id; call })
      (function
        | Request { id; call } -> Some (id, call)
        | _ -> None)
  in
  let case_response =
    Variant.case tag_response
      (tuple2 int64 Rpc_cbor.response_codec)
      (fun (id, response) -> Response { id; response })
      (function
        | Response { id; response } -> Some (id, response)
        | _ -> None)
  in
  let case_push =
    Variant.case tag_push
      push_kind_codec
      (fun kind -> Push kind)
      (function
        | Push kind -> Some kind
        | _ -> None)
  in
  let case_event =
    Variant.case tag_event
      event_kind_codec
      (fun kind -> Event kind)
      (function
        | Event kind -> Some kind
        | _ -> None)
  in
  Variant.variant [ case_request; case_response; case_push; case_event ]

let encode msg = Cbort.encode_string message_codec msg

let decode s =
  match Cbort.decode_string message_codec s with
  | Ok msg -> Ok msg
  | Error e -> Error (Cbort.Error.to_string e)

let decode_exn s =
  match decode s with
  | Ok msg -> msg
  | Error e -> failwith e

let encode_request id call = encode (Request { id; call })

let encode_response id response = encode (Response { id; response })

let encode_push kind = encode (Push kind)

let encode_event kind = encode (Event kind)

let push_stdout data = encode_push (Output { stream = `Stdout; data })

let push_stderr data = encode_push (Output { stream = `Stderr; data })

let push_widget_update ~widget_id state =
  encode_push (Widget_update { widget_id; state })

let push_progress ~task_id ~percent ?message () =
  encode_push (Progress { task_id; percent; message })
