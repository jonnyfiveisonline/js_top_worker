(** CBOR encoding for Rpc.t values. *)

(** We use tagged encoding to distinguish Rpc.t variants in CBOR:
    - Tag 0: Int (int64)
    - Tag 1: Int32
    - Tag 2: Bool
    - Tag 3: Float
    - Tag 4: String
    - Tag 5: DateTime
    - Tag 6: Enum (array)
    - Tag 7: Dict (map)
    - Tag 8: Base64 (bytes)
    - Null: CBOR null (no tag needed)
*)

let codec : Rpc.t Cbort.t =
  let open Cbort in
  fix @@ fun self ->
  let case_int =
    Variant.case 0 int64
      (fun i -> Rpc.Int i)
      (function Rpc.Int i -> Some i | _ -> None)
  in
  let case_int32 =
    Variant.case 1 int32
      (fun i -> Rpc.Int32 i)
      (function Rpc.Int32 i -> Some i | _ -> None)
  in
  let case_bool =
    Variant.case 2 bool
      (fun b -> Rpc.Bool b)
      (function Rpc.Bool b -> Some b | _ -> None)
  in
  let case_float =
    Variant.case 3 float
      (fun f -> Rpc.Float f)
      (function Rpc.Float f -> Some f | _ -> None)
  in
  let case_string =
    Variant.case 4 string
      (fun s -> Rpc.String s)
      (function Rpc.String s -> Some s | _ -> None)
  in
  let case_datetime =
    Variant.case 5 string
      (fun s -> Rpc.DateTime s)
      (function Rpc.DateTime s -> Some s | _ -> None)
  in
  let case_enum =
    Variant.case 6 (array self)
      (fun l -> Rpc.Enum l)
      (function Rpc.Enum l -> Some l | _ -> None)
  in
  let case_dict =
    Variant.case 7 (string_map self)
      (fun l -> Rpc.Dict l)
      (function Rpc.Dict l -> Some l | _ -> None)
  in
  let case_base64 =
    Variant.case 8 bytes
      (fun s -> Rpc.Base64 s)
      (function Rpc.Base64 s -> Some s | _ -> None)
  in
  let case_null =
    Variant.case0 9 Rpc.Null
      (function Rpc.Null -> true | _ -> false)
  in
  Variant.variant [
    case_int;
    case_int32;
    case_bool;
    case_float;
    case_string;
    case_datetime;
    case_enum;
    case_dict;
    case_base64;
    case_null;
  ]

let encode v = Cbort.encode_string codec v

let decode s = Cbort.decode_string codec s

let decode_exn s = Cbort.decode_string_exn codec s

(* RPC call codec *)
let call_codec : Rpc.call Cbort.t =
  let ( let* ) = Cbort.Obj.( let* ) in
  Cbort.Obj.finish
    (let* name =
       Cbort.Obj.mem "name" (fun (c : Rpc.call) -> c.name) Cbort.string
     in
     let* params =
       Cbort.Obj.mem "params" (fun (c : Rpc.call) -> c.params) (Cbort.array codec)
     in
     let* is_notification =
       Cbort.Obj.mem "is_notification" (fun (c : Rpc.call) -> c.is_notification) Cbort.bool
     in
     Cbort.Obj.return { Rpc.name; params; is_notification })

let encode_call c = Cbort.encode_string call_codec c

let decode_call s = Cbort.decode_string call_codec s

(* RPC response codec *)
let response_codec : Rpc.response Cbort.t =
  let ( let* ) = Cbort.Obj.( let* ) in
  Cbort.Obj.finish
    (let* success =
       Cbort.Obj.mem "success" (fun (r : Rpc.response) -> r.success) Cbort.bool
     in
     let* contents =
       Cbort.Obj.mem "contents" (fun (r : Rpc.response) -> r.contents) codec
     in
     let* is_notification =
       Cbort.Obj.mem "is_notification" (fun (r : Rpc.response) -> r.is_notification) Cbort.bool
     in
     Cbort.Obj.return { Rpc.success; contents; is_notification })

let encode_response r = Cbort.encode_string response_codec r

let decode_response s = Cbort.decode_string response_codec s

(* Message envelope types for protocol-level encoding (includes request ID) *)

type request = {
  id : Rpc.t;
  call : Rpc.call;
}

type response_msg = {
  id : Rpc.t;
  response : Rpc.response;
}

(* Request envelope codec *)
let request_codec : request Cbort.t =
  let ( let* ) = Cbort.Obj.( let* ) in
  Cbort.Obj.finish
    (let* id =
       Cbort.Obj.mem "id" (fun (r : request) -> r.id) codec
     in
     let* call =
       Cbort.Obj.mem "call" (fun (r : request) -> r.call) call_codec
     in
     Cbort.Obj.return { id; call })

(* Response envelope codec *)
let response_msg_codec : response_msg Cbort.t =
  let ( let* ) = Cbort.Obj.( let* ) in
  Cbort.Obj.finish
    (let* id =
       Cbort.Obj.mem "id" (fun (r : response_msg) -> r.id) codec
     in
     let* response =
       Cbort.Obj.mem "response" (fun (r : response_msg) -> r.response) response_codec
     in
     Cbort.Obj.return { id; response })

let encode_request r = Cbort.encode_string request_codec r

let decode_request s = Cbort.decode_string request_codec s

let encode_response_msg r = Cbort.encode_string response_msg_codec r

let decode_response_msg s = Cbort.decode_string response_msg_codec s

(* Convenience functions matching Jsonrpc API *)

let string_of_call ?(id = Rpc.Int 0L) call =
  encode_request { id; call }

let id_and_call_of_string s =
  match decode_request s with
  | Ok req -> (req.id, req.call)
  | Error e -> failwith (Cbort.Error.to_string e)

let string_of_response ~id response =
  encode_response_msg { id; response }

let response_of_string s =
  match decode_response_msg s with
  | Ok msg -> msg.response
  | Error e -> failwith (Cbort.Error.to_string e)
