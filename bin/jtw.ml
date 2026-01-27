(** Try to relativize a path against findlib_dir. If the result contains
    ".." (indicating the path is in a different tree), fall back to extracting
    the path components after "lib" directory. *)
let relativize_or_fallback ~findlib_dir path =
  (* First try standard relativize *)
  let rel = match Fpath.relativize ~root:findlib_dir path with
    | Some rel -> rel
    | None -> path (* shouldn't happen for absolute paths, but fallback *)
  in
  (* If the result contains "..", use fallback instead *)
  let segs = Fpath.segs rel in
  if List.mem ".." segs then begin
    (* Fallback: use path components after "lib" directory *)
    let path_segs = Fpath.segs path in
    let rec find_after_lib = function
      | [] -> Fpath.v (Fpath.basename path)
      | "lib" :: rest -> Fpath.v (String.concat Fpath.dir_sep rest)
      | _ :: rest -> find_after_lib rest
    in
    find_after_lib path_segs
  end else
    rel

let cmi_files dir =
  Bos.OS.Dir.fold_contents ~traverse:`None ~elements:`Files
    (fun path acc ->
      if Fpath.has_ext ".cmi" path then Fpath.filename path :: acc else acc)
    [] dir

let gen_cmis ?path_prefix cmis =
  let gen_one (dir, cmis) =
    let all_cmis =
      List.map (fun s -> String.sub s 0 (String.length s - 4)) cmis
    in
    let hidden, non_hidden =
      List.partition (fun x -> Astring.String.is_infix ~affix:"__" x) all_cmis
    in
    let prefixes =
      List.filter_map
        (fun x ->
          match Astring.String.cuts ~sep:"__" x with
          | x :: _ -> Some (x ^ "__")
          | _ -> None)
        hidden
    in
    let prefixes = Util.StringSet.(of_list prefixes |> to_list) in
    let findlib_dir = Ocamlfind.findlib_dir () |> Fpath.v in
    let d = relativize_or_fallback ~findlib_dir dir in
    (* Include path_prefix in dcs_url so it's correct relative to HTTP root *)
    let dcs_url_path = match path_prefix with
      | Some prefix -> Fpath.(v prefix / "lib" // d)
      | None -> Fpath.(v "lib" // d)
    in
    let dcs =
      {
        Js_top_worker_rpc.Toplevel_api_gen.dcs_url = Fpath.to_string dcs_url_path;
        dcs_toplevel_modules = List.map String.capitalize_ascii non_hidden;
        dcs_file_prefixes = prefixes;
      }
    in
    ( dir,
      Jsonrpc.to_string
        (Rpcmarshal.marshal
           Js_top_worker_rpc.Toplevel_api_gen.typ_of_dynamic_cmis dcs) )
  in
  List.map gen_one cmis

(** Read dependency paths from a file (one path per line) *)
let read_deps_file path =
  match Bos.OS.File.read_lines (Fpath.v path) with
  | Ok lines -> List.filter (fun s -> String.length s > 0) lines
  | Error (`Msg m) ->
      Format.eprintf "Warning: Failed to read deps file %s: %s\n%!" path m;
      []

let opam verbose output_dir_str switch libraries no_worker path deps_file =
  Opam.switch := switch;
  (* When --path is specified, only compile the specified libraries (no deps) *)
  let libraries_with_deps, libraries_only =
    match Ocamlfind.deps libraries with
    | Ok l ->
        let all = Util.StringSet.of_list ("stdlib" :: l) in
        (* In --path mode, don't auto-add stdlib - only include requested libs *)
        let only = Util.StringSet.of_list libraries in
        (all, only)
    | Error (`Msg m) ->
        Format.eprintf "Failed to find libs: %s\n%!" m;
        failwith ("Bad libs: " ^ m)
  in
  (* In path mode, only compile the specified packages *)
  let libraries = if path <> None then libraries_only else libraries_with_deps in
  (* Read dependency paths from file if specified *)
  let dep_paths = match deps_file with
    | Some f -> read_deps_file f
    | None -> []
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  if verbose then Logs.set_level (Some Logs.Debug) else Logs.set_level None;
  Logs.set_reporter (Logs_fmt.reporter ());
  let () = Worker_pool.start_workers env sw 16 in
  Logs.debug (fun m ->
      m "Libraries: %a"
        (Fmt.list ~sep:Fmt.comma Fmt.string)
        (Util.StringSet.elements libraries));
  (* output_dir is always from -o; --path is a subdirectory within it *)
  let base_output_dir = Fpath.v output_dir_str in
  let output_dir =
    match path with
    | Some p -> Fpath.(base_output_dir // v p)
    | None -> base_output_dir
  in
  let meta_files =
    List.map
      (fun lib -> Ocamlfind.meta_file lib)
      (Util.StringSet.elements libraries)
    |> Util.StringSet.of_list
  in
  let cmi_dirs =
    match Ocamlfind.deps (Util.StringSet.to_list libraries) with
    | Ok libs ->
        let dirs =
          List.filter_map
            (fun lib ->
              match Ocamlfind.get_dir lib with Ok x -> Some x | _ -> None)
            libs
        in
        dirs
    | Error (`Msg m) ->
        Format.eprintf "Failed to find libs: %s\n%!" m;
        []
  in
  Format.eprintf "cmi_dirs: %a\n%!" (Fmt.list ~sep:Fmt.comma Fpath.pp) cmi_dirs;
  (* In --path mode, only include cmi dirs from specified libraries and their
     subpackages, not external dependencies *)
  let cmi_dirs_to_copy =
    if path <> None then
      let lib_dirs =
        List.filter_map
          (fun lib ->
            match Ocamlfind.get_dir lib with Ok x -> Some x | _ -> None)
          (Util.StringSet.to_list libraries)
      in
      (* Filter cmi_dirs to include directories that are equal to or subdirectories
         of lib_dirs. This includes subpackages like base.base_internalhash_types.
         We check that the relative path doesn't start with ".." *)
      List.filter
        (fun dir ->
          List.exists
            (fun lib_dir ->
              Fpath.equal dir lib_dir ||
              match Fpath.relativize ~root:lib_dir dir with
              | Some rel ->
                  let segs = Fpath.segs rel in
                  (match segs with
                   | ".." :: _ -> false  (* Goes outside lib_dir *)
                   | _ -> true)
              | None -> false)
            lib_dirs)
        cmi_dirs
    else
      cmi_dirs
  in
  let cmis =
    List.fold_left
      (fun acc dir ->
        match cmi_files dir with
        | Ok files -> (dir, files) :: acc
        | Error _ -> acc)
      [] cmi_dirs_to_copy
  in
  let ( let* ) = Result.bind in

  let _ =
    let* _ = Bos.OS.Dir.create output_dir in
    let findlib_dir = Ocamlfind.findlib_dir () |> Fpath.v in

    List.iter
      (fun (dir, files) ->
        let d = relativize_or_fallback ~findlib_dir dir in
        List.iter
          (fun f ->
            let dest_dir = Fpath.(output_dir / "lib" // d) in
            let dest = Fpath.(dest_dir / f) in
            let _ = Bos.OS.Dir.create ~path:true dest_dir in
            match Bos.OS.File.exists dest with
            | Ok true -> ()
            | Ok false -> Util.cp Fpath.(dir / f) dest
            | Error _ -> failwith "file exists failed")
          files)
      cmis;

    let meta_rels =
      Util.StringSet.fold
        (fun meta_file acc ->
          let meta_file = Fpath.v meta_file in
          let d =
            Fpath.relativize ~root:findlib_dir meta_file
            |> Option.get |> Fpath.parent
          in
          (meta_file, d) :: acc)
        meta_files []
    in

    List.iter
      (fun (meta_file, d) ->
        let dest = Fpath.(output_dir / "lib" // d) in
        let _ = Bos.OS.Dir.create dest in
        Util.cp meta_file dest)
      meta_rels;

    (* Generate findlib_index as JSON with metas field *)
    let metas_json =
      List.map
        (fun (meta_file, d) ->
          let file = Fpath.filename meta_file in
          let rel_path = Fpath.(v "lib" // d / file) in
          `String (Fpath.to_string rel_path))
        meta_rels
    in
    (* TODO: dep_paths should also contribute META paths once we have full universe info *)
    let _ = dep_paths in
    let findlib_json = `Assoc [("metas", `List metas_json)] in
    Out_channel.with_open_bin
      Fpath.(output_dir / "findlib_index" |> to_string)
      (fun oc -> Printf.fprintf oc "%s\n" (Yojson.Safe.to_string findlib_json));

    (* Compile archives for each library AND its subpackages *)
    Util.StringSet.iter
      (fun lib ->
        (* Get subpackages (e.g., base.base_internalhash_types for base) *)
        let sub_libs = Ocamlfind.sub_libraries lib in
        let all_libs = Util.StringSet.add lib sub_libs in
        Util.StringSet.iter
          (fun sub_lib ->
            match Ocamlfind.get_dir sub_lib with
            | Error _ -> ()
            | Ok dir ->
                let archives = Ocamlfind.archives sub_lib in
                let archives = List.map (fun x -> Fpath.(dir / x)) archives in
                let d = relativize_or_fallback ~findlib_dir dir in
                let dest = Fpath.(output_dir / "lib" // d) in
                let (_ : (bool, _) result) = Bos.OS.Dir.create dest in
                let compile_archive archive =
                  let output = Fpath.(dest / (Fpath.filename archive ^ ".js")) in
                  let js_runtime = Ocamlfind.jsoo_runtime sub_lib in
                  let js_files =
                    List.map (fun f -> Fpath.(dir / f |> to_string)) js_runtime
                  in
                  let base_cmd =
                    match switch with
                    | None -> Bos.Cmd.(v "js_of_ocaml")
                    | Some s ->
                        Bos.Cmd.(v "opam" % "exec" % "--switch" % s % "--" % "js_of_ocaml")
                  in
                  let cmd =
                    Bos.Cmd.(
                      base_cmd % "compile" % "--toplevel" % "--include-runtime"
                      % "--effects=disabled")
                  in
                  let cmd = List.fold_left (fun c f -> Bos.Cmd.(c % f)) cmd js_files in
                  let cmd =
                    Bos.Cmd.(cmd % Fpath.to_string archive % "-o" % Fpath.to_string output)
                  in
                  ignore (Util.lines_of_process cmd)
                in
                List.iter compile_archive archives)
          all_libs)
      libraries;

    (* Format.eprintf "@[<hov 2>dir: %a [%a]@]\n%!" Fpath.pp dir (Fmt.list ~sep:Fmt.sp Fmt.string) files) cmis; *)
    Ok ()
  in
  let init_cmis = gen_cmis ?path_prefix:path cmis in
  List.iter
    (fun (dir, dcs) ->
      let findlib_dir = Ocamlfind.findlib_dir () |> Fpath.v in
      let d = Fpath.relativize ~root:findlib_dir dir in
      match d with
      | None ->
          Format.eprintf "Failed to relativize %a wrt %a\n%!" Fpath.pp dir
            Fpath.pp findlib_dir
      | Some dir ->
          Format.eprintf "Generating %a\n%!" Fpath.pp dir;
          let dir = Fpath.(output_dir / "lib" // dir) in
          let _ = Bos.OS.Dir.create dir in
          let oc = open_out Fpath.(dir / "dynamic_cmis.json" |> to_string) in
          Printf.fprintf oc "%s" dcs;
          close_out oc)
    init_cmis;
  Format.eprintf "Number of cmis: %d\n%!" (List.length init_cmis);

  let () =
    if no_worker then () else Mk_backend.mk switch output_dir
  in

  `Ok ()

(** Generate a single package's universe directory.
    Returns (pkg_path, meta_path) where meta_path is the full path to META
    relative to the output_dir root. *)
let generate_package_universe ~switch ~output_dir ~findlib_dir ~pkg ~pkg_deps =
  (* Use package name as directory path *)
  let pkg_path = pkg in
  let pkg_output_dir = Fpath.(output_dir / pkg_path) in
  let _ = Bos.OS.Dir.create ~path:true pkg_output_dir in

  (* Get the package's directory and copy cmi files *)
  let pkg_dir = match Ocamlfind.get_dir pkg with
    | Ok d -> d
    | Error _ -> failwith ("Cannot find package: " ^ pkg)
  in

  (* Also include subpackages (directories under pkg_dir) *)
  let all_pkg_dirs =
    let sub_libs = Ocamlfind.sub_libraries pkg in
    Util.StringSet.fold (fun sub acc ->
      match Ocamlfind.get_dir sub with
      | Ok d -> d :: acc
      | Error _ -> acc)
      sub_libs [pkg_dir]
    |> List.sort_uniq Fpath.compare
  in

  (* Copy cmi files *)
  List.iter (fun dir ->
    match cmi_files dir with
    | Ok files ->
        let d = relativize_or_fallback ~findlib_dir dir in
        List.iter (fun f ->
          let dest_dir = Fpath.(pkg_output_dir / "lib" // d) in
          let dest = Fpath.(dest_dir / f) in
          let _ = Bos.OS.Dir.create ~path:true dest_dir in
          match Bos.OS.File.exists dest with
          | Ok true -> ()
          | Ok false -> Util.cp Fpath.(dir / f) dest
          | Error _ -> ())
          files
    | Error _ -> ())
    all_pkg_dirs;

  (* Copy META file *)
  let meta_file = Fpath.v (Ocamlfind.meta_file pkg) in
  let meta_rel = relativize_or_fallback ~findlib_dir meta_file |> Fpath.parent in
  let meta_dest = Fpath.(pkg_output_dir / "lib" // meta_rel) in
  let _ = Bos.OS.Dir.create ~path:true meta_dest in
  Util.cp meta_file meta_dest;

  (* Compile archives for main package and all subpackages *)
  let sub_libs = Ocamlfind.sub_libraries pkg in
  let all_libs = Util.StringSet.add pkg sub_libs in
  Util.StringSet.iter (fun lib ->
    match Ocamlfind.get_dir lib with
    | Error _ -> ()
    | Ok lib_dir ->
        let archives = Ocamlfind.archives lib in
        let archives = List.map (fun x -> Fpath.(lib_dir / x)) archives in
        let d = relativize_or_fallback ~findlib_dir lib_dir in
        let dest = Fpath.(pkg_output_dir / "lib" // d) in
        let _ = Bos.OS.Dir.create ~path:true dest in
        List.iter (fun archive ->
          let output = Fpath.(dest / (Fpath.filename archive ^ ".js")) in
          let js_runtime = Ocamlfind.jsoo_runtime lib in
          let js_files = List.map (fun f -> Fpath.(lib_dir / f |> to_string)) js_runtime in
          let base_cmd = match switch with
            | None -> Bos.Cmd.(v "js_of_ocaml")
            | Some s -> Bos.Cmd.(v "opam" % "exec" % "--switch" % s % "--" % "js_of_ocaml")
          in
          let cmd = Bos.Cmd.(base_cmd % "compile" % "--toplevel" % "--include-runtime" % "--effects=disabled") in
          let cmd = List.fold_left (fun c f -> Bos.Cmd.(c % f)) cmd js_files in
          let cmd = Bos.Cmd.(cmd % Fpath.to_string archive % "-o" % Fpath.to_string output) in
          ignore (Util.lines_of_process cmd))
          archives)
    all_libs;

  (* Generate dynamic_cmis.json for each directory *)
  List.iter (fun dir ->
    match cmi_files dir with
    | Ok files ->
        let all_cmis = List.map (fun s -> String.sub s 0 (String.length s - 4)) files in
        let hidden, non_hidden = List.partition (fun x -> Astring.String.is_infix ~affix:"__" x) all_cmis in
        let prefixes = List.filter_map (fun x ->
          match Astring.String.cuts ~sep:"__" x with
          | x :: _ -> Some (x ^ "__")
          | _ -> None) hidden in
        let prefixes = Util.StringSet.(of_list prefixes |> to_list) in
        let d = relativize_or_fallback ~findlib_dir dir in
        (* Include pkg_path in dcs_url so it's correct relative to the HTTP root *)
        let dcs = {
          Js_top_worker_rpc.Toplevel_api_gen.dcs_url = Fpath.(v pkg_path / "lib" // d |> to_string);
          dcs_toplevel_modules = List.map String.capitalize_ascii non_hidden;
          dcs_file_prefixes = prefixes;
        } in
        let dcs_json = Jsonrpc.to_string (Rpcmarshal.marshal Js_top_worker_rpc.Toplevel_api_gen.typ_of_dynamic_cmis dcs) in
        let dcs_dir = Fpath.(pkg_output_dir / "lib" // d) in
        let _ = Bos.OS.Dir.create ~path:true dcs_dir in
        let oc = open_out Fpath.(dcs_dir / "dynamic_cmis.json" |> to_string) in
        Printf.fprintf oc "%s" dcs_json;
        close_out oc
    | Error _ -> ())
    all_pkg_dirs;

  (* Return pkg_path and the META path relative to pkg_path *)
  let local_meta_path = Fpath.(v "lib" // meta_rel / "META" |> to_string) in
  (pkg_path, local_meta_path, pkg_deps)

let opam_all verbose output_dir_str switch libraries no_worker all_pkgs =
  Opam.switch := switch;

  (* Get all packages and their dependencies *)
  let all_packages =
    if all_pkgs then
      (* Build all installed packages *)
      Ocamlfind.all ()
    else if libraries = [] then
      (* No packages specified, just stdlib *)
      ["stdlib"]
    else
      match Ocamlfind.deps libraries with
      | Ok l -> "stdlib" :: l
      | Error (`Msg m) -> failwith ("Failed to find libs: " ^ m)
  in

  (* Remove duplicates and sort *)
  let all_packages = Util.StringSet.(of_list all_packages |> to_list) in

  Format.eprintf "Generating universes for %d packages\n%!" (List.length all_packages);

  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  if verbose then Logs.set_level (Some Logs.Debug) else Logs.set_level None;
  Logs.set_reporter (Logs_fmt.reporter ());
  let () = Worker_pool.start_workers env sw 16 in

  let output_dir = Fpath.v output_dir_str in
  let _ = Bos.OS.Dir.create ~path:true output_dir in
  let findlib_dir = Ocamlfind.findlib_dir () |> Fpath.v in

  (* Build dependency map: package -> list of direct dependency paths *)
  let dep_map = Hashtbl.create 64 in
  List.iter (fun pkg ->
    let deps = match Ocamlfind.deps [pkg] with
      | Ok l -> List.filter (fun d -> d <> pkg) l  (* Remove self from deps *)
      | Error _ -> []
    in
    Hashtbl.add dep_map pkg deps)
    all_packages;

  (* Generate each package and collect results *)
  let pkg_results = List.map (fun pkg ->
    Format.eprintf "Generating %s...\n%!" pkg;
    let pkg_deps = Hashtbl.find dep_map pkg in
    generate_package_universe ~switch ~output_dir ~findlib_dir ~pkg ~pkg_deps)
    all_packages
  in

  (* Build a map from package name to full META path *)
  let meta_path_map = Hashtbl.create 64 in
  List.iter (fun (pkg_path, local_meta_path, _deps) ->
    let full_meta_path = pkg_path ^ "/" ^ local_meta_path in
    Hashtbl.add meta_path_map pkg_path full_meta_path)
    pkg_results;

  (* Generate findlib_index for each package with correct META paths *)
  List.iter (fun (pkg_path, local_meta_path, deps) ->
    let this_meta = pkg_path ^ "/" ^ local_meta_path in
    let dep_metas = List.filter_map (fun dep ->
      match Hashtbl.find_opt meta_path_map dep with
      | Some path -> Some path
      | None ->
          Format.eprintf "Warning: no META path found for dep %s\n%!" dep;
          None)
      deps
    in
    let all_metas = this_meta :: dep_metas in
    let findlib_json = `Assoc [("metas", `List (List.map (fun s -> `String s) all_metas))] in
    Out_channel.with_open_bin Fpath.(output_dir / pkg_path / "findlib_index" |> to_string)
      (fun oc -> Printf.fprintf oc "%s\n" (Yojson.Safe.to_string findlib_json)))
    pkg_results;

  (* Generate root findlib_index with all META paths *)
  let all_metas = List.map (fun (pkg_path, local_meta_path, _) ->
    pkg_path ^ "/" ^ local_meta_path)
    pkg_results
  in
  let root_index = `Assoc [("metas", `List (List.map (fun s -> `String s) all_metas))] in
  Out_channel.with_open_bin Fpath.(output_dir / "findlib_index" |> to_string)
    (fun oc -> Printf.fprintf oc "%s\n" (Yojson.Safe.to_string root_index));

  Format.eprintf "Generated root findlib_index with %d META files\n%!" (List.length pkg_results);

  (* Generate worker.js if requested *)
  let () = if no_worker then () else Mk_backend.mk switch output_dir in

  `Ok ()

open Cmdliner

let opam_cmd =
  let libraries = Arg.(value & pos_all string [] & info [] ~docv:"LIB") in
  let output_dir =
    let doc =
      "Output directory in which to put all outputs. This should be the root \
       directory of the HTTP server. Ignored when --path is specified."
    in
    Arg.(value & opt string "html" & info [ "o"; "output" ] ~doc)
  in
  let verbose =
    let doc = "Enable verbose logging" in
    Arg.(value & flag & info [ "v"; "verbose" ] ~doc) in
  let no_worker =
    let doc = "Do not create worker.js" in
    Arg.(value & flag & info [ "no-worker" ] ~doc)
  in
  let switch =
    let doc = "Opam switch to use" in
    Arg.(value & opt (some string) None & info [ "switch" ] ~doc)
  in
  let path =
    let doc =
      "Full output path for this package (e.g., universes/abc123/base/v0.17.1/). \
       When specified, only the named packages are compiled (not dependencies)."
    in
    Arg.(value & opt (some string) None & info [ "path" ] ~doc)
  in
  let deps_file =
    let doc =
      "File containing dependency paths, one per line. Each path should be \
       relative to the HTTP root (e.g., universes/xyz789/sexplib0/v0.17.0/)."
    in
    Arg.(value & opt (some string) None & info [ "deps-file" ] ~doc)
  in
  let info = Cmd.info "opam" ~doc:"Generate opam files" in
  Cmd.v info
    Term.(ret (const opam $ verbose $ output_dir $ switch $ libraries $ no_worker $ path $ deps_file))

let opam_all_cmd =
  let libraries = Arg.(value & pos_all string [] & info [] ~docv:"LIB") in
  let output_dir =
    let doc =
      "Output directory for all universes. Each package gets its own subdirectory."
    in
    Arg.(value & opt string "html" & info [ "o"; "output" ] ~doc)
  in
  let verbose =
    let doc = "Enable verbose logging" in
    Arg.(value & flag & info [ "v"; "verbose" ] ~doc)
  in
  let no_worker =
    let doc = "Do not create worker.js" in
    Arg.(value & flag & info [ "no-worker" ] ~doc)
  in
  let switch =
    let doc = "Opam switch to use" in
    Arg.(value & opt (some string) None & info [ "switch" ] ~doc)
  in
  let all_pkgs =
    let doc = "Build all installed packages (from ocamlfind list)" in
    Arg.(value & flag & info [ "all" ] ~doc)
  in
  let info = Cmd.info "opam-all" ~doc:"Generate universes for all packages and their dependencies" in
  Cmd.v info
    Term.(ret (const opam_all $ verbose $ output_dir $ switch $ libraries $ no_worker $ all_pkgs))

let main_cmd =
  let doc = "An odoc notebook tool" in
  let info = Cmd.info "odoc-notebook" ~version:"%%VERSION%%" ~doc in
  let default = Term.(ret (const (`Help (`Pager, None)))) in
  Cmd.group info ~default [ opam_cmd; opam_all_cmd ]

let () = exit (Cmd.eval main_cmd)
