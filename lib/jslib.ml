let log fmt =
  Format.kasprintf
    (fun s -> Js_of_ocaml.(Console.console##log (Js.string s)))
    fmt

let map_url url =
  let open Js_of_ocaml in
  let global_rel_url =
    let x : Js.js_string Js.t option =
      Js.Unsafe.js_expr "globalThis.__global_rel_url" |> Js.Optdef.to_option
    in
    Option.map Js.to_string x
  in
  match global_rel_url with
  | Some rel ->
      (* If url starts with /, it's relative to server root - just use the scheme/host *)
      if String.length url > 0 && url.[0] = '/' then
        (* Extract scheme://host from rel and append url *)
        match String.index_opt rel ':' with
        | Some colon_idx ->
            let after_scheme = colon_idx + 3 in (* skip "://" *)
            (match String.index_from_opt rel after_scheme '/' with
             | Some slash_idx -> String.sub rel 0 slash_idx ^ url
             | None -> rel ^ url)
        | None -> url
      else
        Filename.concat rel url
  | None -> url

let sync_get url =
  let open Js_of_ocaml in
  let url = map_url url in
  Console.console##log (Js.string ("Fetching: " ^ url));
  let x = XmlHttpRequest.create () in
  x##.responseType := Js.string "arraybuffer";
  x##_open (Js.string "GET") (Js.string url) Js._false;
  x##send Js.null;
  match x##.status with
  | 200 ->
      Js.Opt.case
        (File.CoerceTo.arrayBuffer x##.response)
        (fun () ->
          Console.console##log (Js.string "Failed to receive file");
          None)
        (fun b -> Some (Typed_array.String.of_arrayBuffer b))
  | _ -> None

let async_get url =
  let ( let* ) = Lwt.bind in
  let open Js_of_ocaml in
  let url = map_url url in
  Console.console##log (Js.string ("Fetching: " ^ url));
  let* frame =
    Js_of_ocaml_lwt.XmlHttpRequest.perform_raw ~response_type:ArrayBuffer url
  in
  match frame.code with
  | 200 ->
      Lwt.return
        (Js.Opt.case frame.content
           (fun () -> Error (`Msg "Failed to receive file"))
           (fun b -> Ok (Typed_array.String.of_arrayBuffer b)))
  | _ ->
      Lwt.return
        (Error (`Msg (Printf.sprintf "Failed to fetch %s: %d" url frame.code)))
