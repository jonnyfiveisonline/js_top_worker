(** Test CBOR encoding of Rpc.t values *)

module Rpc_cbor = Js_top_worker_rpc.Rpc_cbor

let () =
  let test_roundtrip name v =
    let encoded = Rpc_cbor.encode v in
    match Rpc_cbor.decode encoded with
    | Ok decoded when decoded = v -> Printf.printf "%s: OK\n" name
    | Ok decoded ->
        Printf.printf "%s: FAIL - mismatch\n  expected: %s\n  got: %s\n"
          name (Rpc.to_string v) (Rpc.to_string decoded)
    | Error e -> Printf.printf "%s: FAIL - %s\n" name (Cbort.Error.to_string e)
  in
  test_roundtrip "Int" (Rpc.Int 42L);
  test_roundtrip "Int negative" (Rpc.Int (-100L));
  test_roundtrip "Int32" (Rpc.Int32 42l);
  test_roundtrip "Bool true" (Rpc.Bool true);
  test_roundtrip "Bool false" (Rpc.Bool false);
  test_roundtrip "Float" (Rpc.Float 3.14);
  test_roundtrip "String" (Rpc.String "hello");
  test_roundtrip "String empty" (Rpc.String "");
  test_roundtrip "DateTime" (Rpc.DateTime "2024-01-20T12:00:00Z");
  test_roundtrip "Null" Rpc.Null;
  test_roundtrip "Base64" (Rpc.Base64 "\x00\x01\x02");
  test_roundtrip "Enum empty" (Rpc.Enum []);
  test_roundtrip "Enum" (Rpc.Enum [Rpc.Int 1L; Rpc.String "a"]);
  test_roundtrip "Dict empty" (Rpc.Dict []);
  test_roundtrip "Dict" (Rpc.Dict [("key", Rpc.Int 42L)]);
  test_roundtrip "Nested" (Rpc.Dict [
    ("list", Rpc.Enum [Rpc.Int 1L; Rpc.Int 2L]);
    ("obj", Rpc.Dict [("inner", Rpc.String "value")]);
  ]);

  print_newline ();

  (* Test call codec *)
  let call = Rpc.call "test_method" [Rpc.String "arg1"; Rpc.Int 42L] in
  let encoded_call = Rpc_cbor.encode_call call in
  (match Rpc_cbor.decode_call encoded_call with
  | Ok decoded when decoded = call -> print_endline "Call: OK"
  | Ok _ -> print_endline "Call: FAIL - mismatch"
  | Error e -> Printf.printf "Call: FAIL - %s\n" (Cbort.Error.to_string e));

  (* Test notification call *)
  let notif = Rpc.notification "notify" [Rpc.Bool true] in
  let encoded_notif = Rpc_cbor.encode_call notif in
  (match Rpc_cbor.decode_call encoded_notif with
  | Ok decoded when decoded = notif -> print_endline "Notification: OK"
  | Ok _ -> print_endline "Notification: FAIL - mismatch"
  | Error e -> Printf.printf "Notification: FAIL - %s\n" (Cbort.Error.to_string e));

  (* Test response codec *)
  let response = Rpc.success (Rpc.String "result") in
  let encoded_response = Rpc_cbor.encode_response response in
  (match Rpc_cbor.decode_response encoded_response with
  | Ok decoded when decoded = response -> print_endline "Success response: OK"
  | Ok _ -> print_endline "Success response: FAIL - mismatch"
  | Error e -> Printf.printf "Success response: FAIL - %s\n" (Cbort.Error.to_string e));

  (* Test failure response *)
  let failure = Rpc.failure (Rpc.String "error message") in
  let encoded_failure = Rpc_cbor.encode_response failure in
  (match Rpc_cbor.decode_response encoded_failure with
  | Ok decoded when decoded = failure -> print_endline "Failure response: OK"
  | Ok _ -> print_endline "Failure response: FAIL - mismatch"
  | Error e -> Printf.printf "Failure response: FAIL - %s\n" (Cbort.Error.to_string e));

  print_newline ();
  print_endline "=== Message Envelope Tests ===";

  (* Test request envelope *)
  let req : Rpc_cbor.request = {
    id = Rpc.Int 42L;
    call = Rpc.call "test_method" [Rpc.String "arg1"];
  } in
  let encoded_req = Rpc_cbor.encode_request req in
  (match Rpc_cbor.decode_request encoded_req with
  | Ok decoded when decoded = req -> print_endline "Request envelope: OK"
  | Ok _ -> print_endline "Request envelope: FAIL - mismatch"
  | Error e -> Printf.printf "Request envelope: FAIL - %s\n" (Cbort.Error.to_string e));

  (* Test response envelope *)
  let resp_msg : Rpc_cbor.response_msg = {
    id = Rpc.Int 42L;
    response = Rpc.success (Rpc.String "result");
  } in
  let encoded_resp = Rpc_cbor.encode_response_msg resp_msg in
  (match Rpc_cbor.decode_response_msg encoded_resp with
  | Ok decoded when decoded = resp_msg -> print_endline "Response envelope: OK"
  | Ok _ -> print_endline "Response envelope: FAIL - mismatch"
  | Error e -> Printf.printf "Response envelope: FAIL - %s\n" (Cbort.Error.to_string e));

  (* Test Jsonrpc-compatible API *)
  let call = Rpc.call "test" [Rpc.Bool true] in
  let id = Rpc.Int 123L in
  let encoded = Rpc_cbor.string_of_call ~id call in
  let (decoded_id, decoded_call) = Rpc_cbor.id_and_call_of_string encoded in
  if decoded_id = id && decoded_call = call then
    print_endline "string_of_call/id_and_call_of_string: OK"
  else
    print_endline "string_of_call/id_and_call_of_string: FAIL - mismatch";

  let response = Rpc.success (Rpc.Int 999L) in
  let encoded_resp = Rpc_cbor.string_of_response ~id response in
  let decoded_resp = Rpc_cbor.response_of_string encoded_resp in
  if decoded_resp = response then
    print_endline "string_of_response/response_of_string: OK"
  else
    print_endline "string_of_response/response_of_string: FAIL - mismatch";

  print_newline ();
  print_endline "All tests complete!"
