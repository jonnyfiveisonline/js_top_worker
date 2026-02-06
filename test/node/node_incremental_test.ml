(* Test incremental output *)
open Js_top_worker
open Js_top_worker_rpc.Toplevel_api_gen
open Impl

let capture : (unit -> 'a) -> unit -> Impl.captured * 'a =
 fun f () ->
  let stdout_buff = Buffer.create 1024 in
  let stderr_buff = Buffer.create 1024 in
  Js_of_ocaml.Sys_js.set_channel_flusher stdout (Buffer.add_string stdout_buff);

  let x = f () in
  let captured =
    {
      Impl.stdout = Buffer.contents stdout_buff;
      stderr = Buffer.contents stderr_buff;
    }
  in
  (captured, x)

module S : Impl.S = struct
  type findlib_t = Js_top_worker_web.Findlibish.t

  let capture = capture

  let sync_get f =
    let f = Fpath.v ("_opam/" ^ f) in
    Logs.info (fun m -> m "sync_get: %a" Fpath.pp f);
    try Some (In_channel.with_open_bin (Fpath.to_string f) In_channel.input_all)
    with e ->
      Logs.err (fun m ->
          m "Error reading file %a: %s" Fpath.pp f (Printexc.to_string e));
      None

  let async_get f =
    let f = Fpath.v ("_opam/" ^ f) in
    Logs.info (fun m -> m "async_get: %a" Fpath.pp f);
    try
      let content =
        In_channel.with_open_bin (Fpath.to_string f) In_channel.input_all
      in
      Lwt.return (Ok content)
    with e ->
      Logs.err (fun m ->
          m "Error reading file %a: %s" Fpath.pp f (Printexc.to_string e));
      Lwt.return (Error (`Msg (Printexc.to_string e)))

  let create_file = Js_of_ocaml.Sys_js.create_file

  let import_scripts urls =
    let open Js_of_ocaml.Js in
    let import_scripts_fn = Unsafe.get Unsafe.global (string "importScripts") in
    List.iter
      (fun url ->
        let (_ : 'a) =
          Unsafe.fun_call import_scripts_fn [| Unsafe.inject (string url) |]
        in
        ())
      urls

  let init_function _ () = failwith "Not implemented"
  let findlib_init = Js_top_worker_web.Findlibish.init async_get

  let get_stdlib_dcs uri =
    Js_top_worker_web.Findlibish.fetch_dynamic_cmis sync_get uri
    |> Result.to_list

  let require b v = function
    | [] -> []
    | packages -> Js_top_worker_web.Findlibish.require ~import_scripts sync_get b v packages

  let path = "/static/cmis"
end

module U = Impl.Make (S)

let _ =
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Info);

  let ( let* ) = IdlM.ErrM.bind in

  let init_config =
    { stdlib_dcs = None; findlib_requires = []; findlib_index = None; execute = true }
  in

  let x =
    let* _ = IdlM.T.lift U.init init_config in
    let* _ = IdlM.T.lift U.setup "" in
    Logs.info (fun m -> m "Setup complete, testing incremental output...");

    (* Test incremental output with multiple phrases *)
    let phrase_outputs = ref [] in
    let on_phrase_output (p : U.phrase_output) =
      Logs.info (fun m -> m "  OutputAt: loc=%d caml_ppf=%s"
        p.loc
        (Option.value ~default:"<none>" p.caml_ppf));
      phrase_outputs := p :: !phrase_outputs
    in

    let code = "let x = 1;; let y = 2;; let z = x + y;;" in
    Logs.info (fun m -> m "Evaluating: %s" code);

    let* result = U.execute_incremental "" code ~on_phrase_output in

    let num_callbacks = List.length !phrase_outputs in
    Logs.info (fun m -> m "Number of OutputAt callbacks: %d (expected 3)" num_callbacks);

    (* Verify we got 3 callbacks (one per phrase) *)
    if num_callbacks <> 3 then
      Logs.err (fun m -> m "FAIL: Expected 3 callbacks, got %d" num_callbacks)
    else
      Logs.info (fun m -> m "PASS: Got expected number of callbacks");

    (* Verify the locations are increasing *)
    let locs = List.rev_map (fun (p : U.phrase_output) -> p.loc) !phrase_outputs in
    let sorted = List.sort compare locs in
    if locs = sorted then
      Logs.info (fun m -> m "PASS: Locations are in increasing order: %s"
        (String.concat ", " (List.map string_of_int locs)))
    else
      Logs.err (fun m -> m "FAIL: Locations are not in order");

    (* Verify final result has expected values *)
    Logs.info (fun m -> m "Final result caml_ppf: %s"
      (Option.value ~default:"<none>" result.caml_ppf));
    Logs.info (fun m -> m "Final result stdout: %s"
      (Option.value ~default:"<none>" result.stdout));

    IdlM.ErrM.return ()
  in

  let promise = x |> IdlM.T.get in
  match Lwt.state promise with
  | Lwt.Return (Ok ()) -> Logs.info (fun m -> m "Test completed successfully")
  | Lwt.Return (Error (InternalError s)) -> Logs.err (fun m -> m "Error: %s" s)
  | Lwt.Fail e ->
      Logs.err (fun m -> m "Unexpected failure: %s" (Printexc.to_string e))
  | Lwt.Sleep ->
      Logs.err (fun m -> m "Error: Promise is still pending")
