let log fmt =
  Format.kasprintf
    (fun s -> Js_of_ocaml.(Console.console##log (Js.string s)))
    fmt

let sync_get url =
  let open Js_of_ocaml in
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

