(* Kinda findlib, sorta *)

type library = {
  name : string;
  meta_uri : Uri.t;
  archive_name : string option;
  dir : string option;
  deps : string list;
  children : library list;
  mutable loaded : bool;
}

let rec flatten_libs libs =
  let handle_lib l =
    let children = flatten_libs l.children in
    l :: children
  in
  List.map handle_lib libs |> List.flatten

let preloaded =
  [
    "angstrom";
    "astring";
    "compiler-libs.common";
    "compiler-libs.toplevel";
    "findlib";
    "findlib.top";
    "fpath";
    "js_of_ocaml-compiler";
    "js_of_ocaml-ppx";
    "js_of_ocaml-toplevel";
    "js_top_worker";
    "js_top_worker-rpc";
    "logs";
    "logs.browser";
    "merlin-lib.kernel";
    "merlin-lib.ocaml_parsing";
    "merlin-lib.query_commands";
    "merlin-lib.query_protocol";
    "merlin-lib.utils";
    "mime_printer";
    "uri";
  ]

let rec read_libraries_from_pkg_defs ~library_name ~dir meta_uri pkg_expr =
  try
    Jslib.log "Reading library: %s" library_name;
    let pkg_defs = pkg_expr.Fl_metascanner.pkg_defs in
    (* Try to find archive with various predicates.
       PPX packages often only define archive(ppx_driver,byte), so we need to
       check multiple predicate combinations to find the right archive. *)
    let archive_filename =
      (* First try with ppx_driver,byte - this catches PPX libraries like ppx_deriving.show *)
      try Some (Fl_metascanner.lookup "archive" [ "ppx_driver"; "byte" ] pkg_defs)
      with _ -> (
        (* Then try plain byte *)
        try Some (Fl_metascanner.lookup "archive" [ "byte" ] pkg_defs)
        with _ -> (
          (* Then try native as fallback *)
          try Some (Fl_metascanner.lookup "archive" [ "native" ] pkg_defs)
          with _ -> None))
    in

    (* Use -ppx_driver predicate for toplevel use - this ensures PPX packages
       pull in their runtime dependencies (e.g., ppx_deriving.show requires
       ppx_deriving.runtime when not using ppx_driver) *)
    let predicates = ["-ppx_driver"] in
    let deps_str =
      try Fl_metascanner.lookup "requires" predicates pkg_defs with _ -> "" in
    let deps = Astring.String.fields ~empty:false deps_str in
    let subdir =
      List.find_opt (fun d -> d.Fl_metascanner.def_var = "directory") pkg_defs
      |> Option.map (fun d -> d.Fl_metascanner.def_value)
    in
    let dir =
      match (dir, subdir) with
      | None, None -> None
      | Some d, None -> Some d
      | None, Some d -> Some d
      | Some d1, Some d2 -> Some (Filename.concat d1 d2)
    in
    let archive_name =
      Option.bind archive_filename (fun a ->
          let file_name_len = String.length a in
          if file_name_len > 0 then Some (Filename.chop_extension a) else None)
    in
    Jslib.log "Number of children: %d" (List.length pkg_expr.pkg_children);
    let children =
      List.filter_map
        (fun (n, expr) ->
          Jslib.log "Found child: %s" n;
          let library_name = library_name ^ "." ^ n in
          match
            read_libraries_from_pkg_defs ~library_name ~dir meta_uri expr
          with
          | Ok l -> Some l
          | Error (`Msg m) ->
              Jslib.log "Error reading sub-library: %s" m;
              None)
        pkg_expr.pkg_children
    in
    Ok
      {
        name = library_name;
        archive_name;
        dir;
        deps;
        meta_uri;
        loaded = false;
        children;
      }
  with Not_found -> Error (`Msg "Failed to read libraries from pkg_defs")

type t = library list

let dcs_filename = "dynamic_cmis.json"

let fetch_dynamic_cmis sync_get url =
  match sync_get url with
  | None -> Error (`Msg "Failed to fetch dynamic cmis")
  | Some json ->
      let rpc = Jsonrpc.of_string json in
      Rpcmarshal.unmarshal
        Js_top_worker_rpc.Toplevel_api_gen.typ_of_dynamic_cmis rpc

let (let*) = Lwt.bind

(** Parse a findlib_index file (JSON or legacy text format) and return
    the list of package paths and dependency universe paths *)
let parse_findlib_index content =
  (* Try JSON format first *)
  try
    let json = Yojson.Safe.from_string content in
    let open Yojson.Safe.Util in
    let packages = json |> member "packages" |> to_list |> List.map to_string in
    let deps = json |> member "deps" |> to_list |> List.map to_string in
    (packages, deps)
  with _ ->
    (* Fall back to legacy whitespace-separated format *)
    let packages = Astring.String.fields ~empty:false content in
    (packages, [])

(** Load a single META file and parse it into a library *)
let load_meta async_get meta_path =
  let* res = async_get meta_path in
  match res with
  | Error (`Msg m) ->
      Jslib.log "Error fetching findlib meta %s: %s" meta_path m;
      Lwt.return_none
  | Ok meta_content ->
      match Angstrom.parse_string ~consume:All Uri.Parser.uri_reference meta_path with
      | Ok uri -> (
          Jslib.log "Parsed uri: %s" (Uri.path uri);
          let path = Uri.path uri in
          let file = Fpath.v path in
          let base_library_name =
            if Fpath.basename file = "META" then
              Fpath.parent file |> Fpath.basename
            else Fpath.get_ext file
          in
          let lexing = Lexing.from_string meta_content in
          try
            let meta = Fl_metascanner.parse_lexing lexing in
            let libraries =
              read_libraries_from_pkg_defs ~library_name:base_library_name
                ~dir:None uri meta
            in
            Lwt.return (Result.to_option libraries)
          with _ ->
            Jslib.log "Failed to parse meta: %s" (Uri.path uri);
            Lwt.return_none)
      | Error m ->
          Jslib.log "Failed to parse uri: %s" m;
          Lwt.return_none

(** Resolve a relative path against a base URL's directory *)
let resolve_url_relative ~base relative =
  match Angstrom.parse_string ~consume:All Uri.Parser.uri_reference base with
  | Ok base_uri ->
      let base_path = Uri.path base_uri in
      let base_dir = Fpath.(v base_path |> parent |> to_string) in
      let resolved = Filename.concat base_dir relative in
      Uri.with_path base_uri resolved |> Uri.to_string
  | Error _ -> relative

(** Resolve a path from the URL root (for dependency universes) *)
let resolve_url_from_root ~base path =
  match Angstrom.parse_string ~consume:All Uri.Parser.uri_reference base with
  | Ok base_uri ->
      let resolved = "/" ^ path in
      Uri.with_path base_uri resolved |> Uri.to_string
  | Error _ -> path

let init (async_get : string -> (string, [>`Msg of string]) result Lwt.t) findlib_index : t Lwt.t =
  Jslib.log "Initializing findlib";
  (* Track visited universes to avoid infinite loops *)
  let visited = Hashtbl.create 16 in
  let rec load_universe index_url =
    if Hashtbl.mem visited index_url then
      Lwt.return []
    else begin
      Hashtbl.add visited index_url ();
      let* findlib_txt = async_get index_url in
      match findlib_txt with
      | Error (`Msg m) ->
          Jslib.log "Error fetching findlib index %s: %s" index_url m;
          Lwt.return []
      | Ok content ->
          let packages, deps = parse_findlib_index content in
          Jslib.log "Loaded universe %s: %d packages, %d deps" index_url
            (List.length packages) (List.length deps);
          (* Resolve package paths relative to the index URL's directory *)
          let resolved_packages =
            List.map (fun p -> resolve_url_relative ~base:index_url p) packages
          in
          (* Load META files from this universe *)
          let* local_libs =
            Lwt_list.filter_map_p (load_meta async_get) resolved_packages
          in
          (* Recursively load dependency universes from root paths *)
          let dep_index_urls =
            List.map (fun dep ->
              resolve_url_from_root ~base:index_url (Filename.concat dep "findlib_index"))
              deps
          in
          let* dep_libs = Lwt_list.map_p load_universe dep_index_urls in
          Lwt.return (local_libs @ List.flatten dep_libs)
    end
  in
  let* all_libs = load_universe findlib_index in
  Lwt.return (flatten_libs all_libs)

let require ~import_scripts sync_get cmi_only v packages =
  let rec require dcss package :
      Js_top_worker_rpc.Toplevel_api_gen.dynamic_cmis list =
    match List.find (fun lib -> lib.name = package) v with
    | exception Not_found ->
        Jslib.log "Package %s not found" package;
        let available =
          v
          |> List.map (fun lib ->
                 Printf.sprintf "%s (%d)" lib.name (List.length lib.children))
          |> String.concat ", "
        in
        Jslib.log "Available packages: %s" available;
        dcss
    | lib ->
        if lib.loaded then dcss
        else (
          Jslib.log "Loading package %s" lib.name;
          Jslib.log "lib.dir: %s" (Option.value ~default:"None" lib.dir);
          let dep_dcs = List.fold_left require dcss lib.deps in
          let path = Fpath.(v (Uri.path lib.meta_uri) |> parent) in
          let dir =
            match lib.dir with
            | None -> path
            | Some "+" -> Fpath.parent path  (* "+" means parent dir in findlib *)
            | Some d when String.length d > 0 && d.[0] = '^' ->
                (* "^" prefix means relative to stdlib dir - treat as parent *)
                Fpath.parent path
            | Some d -> Fpath.(path // v d)
          in
          let dcs = Fpath.(dir / dcs_filename |> to_string) in
          let uri = Uri.with_path lib.meta_uri dcs in
          Jslib.log "uri: %s" (Uri.to_string uri);
          match fetch_dynamic_cmis sync_get (Uri.to_string uri) with
          | Ok dcs ->
              let should_load =
                (not (List.mem lib.name preloaded)) && not cmi_only
              in
              Option.iter
                (fun archive ->
                  if should_load then begin
                    let archive_js =
                      Fpath.(dir / (archive ^ ".cma.js") |> to_string)
                    in
                    import_scripts
                      [ Uri.with_path uri archive_js |> Uri.to_string ]
                  end)
                lib.archive_name;
              lib.loaded <- true;
              Jslib.log "Finished loading package %s" lib.name;
              dcs :: dep_dcs
          | Error (`Msg m) ->
              Jslib.log "Failed to unmarshal dynamic_cms from url %s: %s"
                (Uri.to_string uri) m;
              dcss)
  in
  List.fold_left require [] packages
