(** Tests for the Channel module (push message support). *)

open Js_top_worker_rpc

let test_request_roundtrip () =
  let id = 42L in
  let call = Rpc.{ name = "test_method"; params = [Rpc.String "arg1"]; is_notification = false } in
  let encoded = Channel.encode_request id call in
  match Channel.decode encoded with
  | Ok (Channel.Request { id = id'; call = call' }) ->
      assert (id = id');
      assert (call.name = call'.name);
      print_endline "Request roundtrip: OK"
  | Ok _ -> failwith "Wrong message type"
  | Error e -> failwith ("Decode error: " ^ e)

let test_response_roundtrip () =
  let id = 123L in
  let response = Rpc.{ success = true; contents = Rpc.String "result"; is_notification = false } in
  let encoded = Channel.encode_response id response in
  match Channel.decode encoded with
  | Ok (Channel.Response { id = id'; response = response' }) ->
      assert (id = id');
      assert (response.success = response'.success);
      print_endline "Response roundtrip: OK"
  | Ok _ -> failwith "Wrong message type"
  | Error e -> failwith ("Decode error: " ^ e)

let test_push_stdout () =
  let data = "Hello, world!" in
  let encoded = Channel.push_stdout data in
  match Channel.decode encoded with
  | Ok (Channel.Push (Channel.Output { stream = `Stdout; data = data' })) ->
      assert (data = data');
      print_endline "Push stdout: OK"
  | Ok _ -> failwith "Wrong message type"
  | Error e -> failwith ("Decode error: " ^ e)

let test_push_stderr () =
  let data = "Error message" in
  let encoded = Channel.push_stderr data in
  match Channel.decode encoded with
  | Ok (Channel.Push (Channel.Output { stream = `Stderr; data = data' })) ->
      assert (data = data');
      print_endline "Push stderr: OK"
  | Ok _ -> failwith "Wrong message type"
  | Error e -> failwith ("Decode error: " ^ e)

let test_push_widget_update () =
  let widget_id = "widget_1" in
  let state = Rpc.Dict [("value", Rpc.Int 42L)] in
  let encoded = Channel.push_widget_update ~widget_id state in
  match Channel.decode encoded with
  | Ok (Channel.Push (Channel.Widget_update { widget_id = id'; state = state' })) ->
      assert (widget_id = id');
      assert (state = state');
      print_endline "Push widget_update: OK"
  | Ok _ -> failwith "Wrong message type"
  | Error e -> failwith ("Decode error: " ^ e)

let test_push_progress () =
  let task_id = "task_1" in
  let percent = 50 in
  let message = Some "Processing..." in
  let encoded = Channel.push_progress ~task_id ~percent ?message () in
  match Channel.decode encoded with
  | Ok (Channel.Push (Channel.Progress { task_id = id'; percent = p'; message = m' })) ->
      assert (task_id = id');
      assert (percent = p');
      assert (message = m');
      print_endline "Push progress: OK"
  | Ok _ -> failwith "Wrong message type"
  | Error e -> failwith ("Decode error: " ^ e)

let test_event_widget () =
  let widget_id = "widget_1" in
  let event_type = "click" in
  let data = Rpc.Dict [("x", Rpc.Int 100L); ("y", Rpc.Int 200L)] in
  let event = Channel.Widget_event { widget_id; event_type; data } in
  let encoded = Channel.encode_event event in
  match Channel.decode encoded with
  | Ok (Channel.Event (Channel.Widget_event { widget_id = id'; event_type = et'; data = d' })) ->
      assert (widget_id = id');
      assert (event_type = et');
      assert (data = d');
      print_endline "Event widget: OK"
  | Ok _ -> failwith "Wrong message type"
  | Error e -> failwith ("Decode error: " ^ e)

let test_custom_push () =
  let kind = "my_custom_push" in
  let data = Rpc.Enum [Rpc.String "a"; Rpc.String "b"] in
  let push = Channel.Custom_push { kind; data } in
  let encoded = Channel.encode_push push in
  match Channel.decode encoded with
  | Ok (Channel.Push (Channel.Custom_push { kind = k'; data = d' })) ->
      assert (kind = k');
      assert (data = d');
      print_endline "Custom push: OK"
  | Ok _ -> failwith "Wrong message type"
  | Error e -> failwith ("Decode error: " ^ e)

let () =
  print_endline "=== Channel Tests ===";
  print_newline ();

  test_request_roundtrip ();
  test_response_roundtrip ();

  print_newline ();
  print_endline "=== Push Message Tests ===";
  test_push_stdout ();
  test_push_stderr ();
  test_push_widget_update ();
  test_push_progress ();
  test_custom_push ();

  print_newline ();
  print_endline "=== Event Tests ===";
  test_event_widget ();

  print_newline ();
  print_endline "All channel tests passed!"
