(** {1 OCaml Toplevel Implementation}

    This module provides the core toplevel functionality for js_top_worker.
    It implements phrase execution, type checking, and Merlin integration
    (completion, errors, type info).

    The module is parameterized by a backend signature [S] which provides
    platform-specific operations for different environments (WebWorker,
    Node.js, Unix). *)

open Js_top_worker_rpc
module M = Rpc_lwt.ErrM (* Server is not synchronous *)
module IdlM = Rpc_lwt

let ( let* ) = Lwt.bind

(** {2 Cell Dependency System}

    Cells are identified by string IDs and can depend on previous cells.
    Each cell is wrapped in a module [Cell__<id>] so that later cells can
    access earlier bindings via [open Cell__<id>]. *)

type captured = { stdout : string; stderr : string }

let modname_of_id id = "Cell__" ^ id

let is_mangled_broken orig src =
  String.length orig <> String.length src
  || Seq.exists2
       (fun c c' -> c <> c' && c' <> ' ')
       (String.to_seq orig) (String.to_seq src)

let mangle_toplevel is_toplevel orig_source deps =
  let src =
    if not is_toplevel then orig_source
    else if
      String.length orig_source < 2
      || orig_source.[0] <> '#'
      || orig_source.[1] <> ' '
    then (
      Logs.err (fun m ->
          m "xx Warning, ignoring toplevel block without a leading '# '.\n%!");
      orig_source)
    else
      try
        let s = String.sub orig_source 2 (String.length orig_source - 2) in
        let list =
          try Ocamltop.parse_toplevel s
          with _ -> Ocamltop.fallback_parse_toplevel s
        in
        let lines =
          List.map
            (fun (phr, junk, output) ->
              let l1 =
                Printf.sprintf "  %s%s" phr
                  (String.make (String.length junk) ' ')
              in
              match output with
              | [] -> l1
              | _ ->
                  let s =
                    List.map (fun x -> String.make (String.length x) ' ') output
                  in
                  String.concat "\n" (l1 :: s))
            list
        in
        String.concat "\n" lines
      with e ->
        Logs.err (fun m ->
            m "Error in mangle_toplevel: %s" (Printexc.to_string e));
        let ppf = Format.err_formatter in
        let _ = Location.report_exception ppf e in
        orig_source
  in
  let line1 =
    List.map (fun id -> Printf.sprintf "open %s" (modname_of_id id)) deps
    |> String.concat " "
  in
  let line1 = if line1 = "" then "" else line1 ^ ";;\n" in
  Logs.debug (fun m -> m "Line 1: '%s'\n%!" line1);
  Logs.debug (fun m -> m "Source: %s\n%!" src);
  if is_mangled_broken orig_source src then (
    Printf.printf "Warning: mangled source is broken\n%!";
    Printf.printf "orig length: %d\n%!" (String.length orig_source);
    Printf.printf "src length: %d\n%!" (String.length src));
  (line1, src)

(** {2 PPX Preprocessing}

    Handles PPX rewriter registration and application. Supports:
    - Old-style [Ast_mapper] PPXs (e.g., [Ppx_js.mapper] for js_of_ocaml)
    - [ppx_deriving]-based PPXs (registered via [Ppx_deriving.register])
    - Modern [ppxlib]-based PPXs (registered via [Ppxlib.Driver])

    The [Ppx_js.mapper] is registered by default to support js_of_ocaml
    syntax extensions. Other PPXs can be dynamically loaded via [#require]. *)

module JsooTopPpx = struct
  open Js_of_ocaml_compiler.Stdlib

  (** Old-style Ast_mapper rewriters *)
  let ppx_rewriters = ref [ (fun _ -> Ppx_js.mapper) ]

  let () =
    Ast_mapper.register_function :=
      fun _ f -> ppx_rewriters := f :: !ppx_rewriters

  (** Apply old-style Ast_mapper rewriters *)
  let apply_ast_mapper_rewriters_structure str =
    let open Ast_mapper in
    List.fold_right !ppx_rewriters ~init:str ~f:(fun ppx_rewriter str ->
        let mapper = ppx_rewriter [] in
        mapper.structure mapper str)

  let apply_ast_mapper_rewriters_signature sg =
    let open Ast_mapper in
    List.fold_right !ppx_rewriters ~init:sg ~f:(fun ppx_rewriter sg ->
        let mapper = ppx_rewriter [] in
        mapper.signature mapper sg)

  (** Apply ppx_deriving transformations using its mapper class.
      This handles [@@deriving] attributes for dynamically loaded derivers. *)
  let apply_ppx_deriving_structure str =
    let mapper = new Ppx_deriving.mapper in
    mapper#structure str

  let apply_ppx_deriving_signature sg =
    let mapper = new Ppx_deriving.mapper in
    mapper#signature sg

  (** Apply all PPX transformations in order:
      1. Old-style Ast_mapper (e.g., Ppx_js)
      2. ppx_deriving derivers
      3. ppxlib-based PPXs
      Handles AST version conversion between compiler's Parsetree and ppxlib's internal AST. *)
  let preprocess_structure str =
    str
    |> apply_ast_mapper_rewriters_structure
    |> Ppxlib_ast.Selected_ast.of_ocaml Structure
    |> apply_ppx_deriving_structure
    |> Ppxlib.Driver.map_structure
    |> Ppxlib_ast.Selected_ast.to_ocaml Structure

  let preprocess_signature sg =
    sg
    |> apply_ast_mapper_rewriters_signature
    |> Ppxlib_ast.Selected_ast.of_ocaml Signature
    |> apply_ppx_deriving_signature
    |> Ppxlib.Driver.map_signature
    |> Ppxlib_ast.Selected_ast.to_ocaml Signature

  let preprocess_phrase phrase =
    let open Parsetree in
    match phrase with
    | Ptop_def str -> Ptop_def (preprocess_structure str)
    | Ptop_dir _ as x -> x
end

(** {2 Backend Signature}

    Platform-specific operations that must be provided by each backend
    (WebWorker, Node.js, Unix). *)

module type S = sig
  type findlib_t

  val capture : (unit -> 'a) -> unit -> captured * 'a
  val create_file : name:string -> content:string -> unit
  val sync_get : string -> string option
  val async_get : string -> (string, [> `Msg of string ]) result Lwt.t
  val import_scripts : string list -> unit
  val init_function : string -> unit -> unit
  val get_stdlib_dcs : string -> Toplevel_api_gen.dynamic_cmis list
  val findlib_init : string -> findlib_t Lwt.t
  val path : string

  val require :
    bool -> findlib_t -> string list -> Toplevel_api_gen.dynamic_cmis list
end

(** {2 Main Functor}

    The toplevel implementation, parameterized by backend operations. *)

module Make (S : S) = struct
  (** {3 Global State}

      These are shared across all environments. *)

  let functions : (unit -> unit) list option ref = ref None
  let requires : string list ref = ref []
  let path : string option ref = ref None
  let findlib_v : S.findlib_t Lwt.t option ref = ref None
  let findlib_resolved : S.findlib_t option ref = ref None
  let execution_allowed = ref true

  (** {3 Environment Management}

      Helper to resolve env_id string to an Environment.t.
      Empty string means the default environment. *)

  let resolve_env env_id =
    let id = if env_id = "" then Environment.default_id else env_id in
    Environment.get_or_create id

  (** {3 Lexer Helpers} *)

  let refill_lexbuf s p ppf buffer len =
    if !p = String.length s then 0
    else
      let len', nl =
        try (String.index_from s !p '\n' - !p + 1, false)
        with _ -> (String.length s - !p, true)
      in
      let len'' = min len len' in
      String.blit s !p buffer 0 len'';
      (match ppf with
      | Some ppf ->
          Format.fprintf ppf "%s" (Bytes.sub_string buffer 0 len'');
          if nl then Format.pp_print_newline ppf ();
          Format.pp_print_flush ppf ()
      | None -> ());
      p := !p + len'';
      len''

  (** {3 Setup and Initialization} *)

  let exec' s =
    S.capture
      (fun () ->
        let res : bool = Toploop.use_silently Format.std_formatter (String s) in
        if not res then Format.eprintf "error while evaluating %s@." s)
      ()

  (** {3 Custom Require Directive}

      Replaces the standard findlib #require with one that loads JavaScript
      archives via importScripts. This is necessary because in js_of_ocaml,
      we can't use Topdirs.dir_load to load .cma files - we need to load
      .cma.js files via importScripts instead. *)

  let add_dynamic_cmis_sync dcs =
    (* Synchronous version for #require directive.
       Fetches and installs toplevel CMIs synchronously. *)
    let furl = "file://" in
    let l = String.length furl in
    if String.length dcs.Toplevel_api_gen.dcs_url > l
       && String.sub dcs.dcs_url 0 l = furl
    then begin
      let path = String.sub dcs.dcs_url l (String.length dcs.dcs_url - l) in
      Topdirs.dir_directory path
    end
    else begin
      (* Web URL - fetch CMIs synchronously *)
      let fetch_sync filename =
        let url = Filename.concat dcs.Toplevel_api_gen.dcs_url filename in
        S.sync_get url
      in
      let path =
        match !path with Some p -> p | None -> failwith "Path not set"
      in
      let to_cmi_filename name =
        Printf.sprintf "%s.cmi" (String.uncapitalize_ascii name)
      in
      Logs.info (fun m -> m "Adding toplevel modules for dynamic cmis from %s" dcs.dcs_url);
      Logs.info (fun m -> m "  toplevel modules: %s"
        (String.concat ", " dcs.dcs_toplevel_modules));
      (* Fetch and create toplevel module CMIs *)
      List.iter
        (fun name ->
          let filename = to_cmi_filename name in
          match fetch_sync filename with
          | Some content ->
              let fs_name = Filename.(concat path filename) in
              (try S.create_file ~name:fs_name ~content with _ -> ())
          | None -> ())
        dcs.dcs_toplevel_modules;
      (* Install on-demand loader for prefixed modules *)
      if dcs.dcs_file_prefixes <> [] then begin
        let open Persistent_env.Persistent_signature in
        let old_loader = !load in
#if OCAML_VERSION >= (5, 2, 0)
        load := fun ~allow_hidden ~unit_name ->
#else
        load := fun ~unit_name ->
#endif
          let filename = to_cmi_filename unit_name in
          let fs_name = Filename.(concat path filename) in
          if (not (Sys.file_exists fs_name))
             && List.exists
                  (fun prefix -> String.starts_with ~prefix filename)
                  dcs.dcs_file_prefixes
          then begin
            Logs.info (fun m -> m "Fetching %s\n%!" filename);
            match fetch_sync filename with
            | Some content ->
                (try S.create_file ~name:fs_name ~content with _ -> ())
            | None -> ()
          end;
#if OCAML_VERSION >= (5, 2, 0)
          old_loader ~allow_hidden ~unit_name
#else
          old_loader ~unit_name
#endif
      end
    end

  let register_require_directive () =
    let require_handler pkg =
      Logs.info (fun m -> m "Custom #require: loading %s" pkg);
      match !findlib_resolved with
      | None ->
          Format.eprintf "Error: findlib not initialized@."
      | Some v ->
          let cmi_only = not !execution_allowed in
          let dcs_list = S.require cmi_only v [pkg] in
          List.iter add_dynamic_cmis_sync dcs_list;
          Logs.info (fun m -> m "Custom #require: %s loaded" pkg)
    in
    (* Replace the standard findlib #require directive with our custom one.
       We use add_directive which will override the existing one. *)
    let info = { Toploop.section = "Findlib"; doc = "Load a package (js_top_worker)" } in
    Toploop.add_directive "require" (Toploop.Directive_string require_handler) info

  let setup functions () =
    let stdout_buff = Buffer.create 100 in
    let stderr_buff = Buffer.create 100 in

    let combine o =
      Buffer.add_string stdout_buff o.stdout;
      Buffer.add_string stderr_buff o.stderr
    in

    let exec' s =
      let o, () = exec' s in
      combine o
    in
    Sys.interactive := false;

    Toploop.input_name := "//toplevel//";
    let path =
      match !path with Some p -> p | None -> failwith "Path not set"
    in

    Topdirs.dir_directory path;

    Toploop.initialize_toplevel_env ();

    List.iter (fun f -> f ()) functions;
    exec' "open Stdlib";
    let header1 = Printf.sprintf "        %s version %%s" "OCaml" in
    exec' (Printf.sprintf "Format.printf \"%s@.\" Sys.ocaml_version;;" header1);
    exec' "#enable \"pretty\";;";
    exec' "#disable \"shortvar\";;";
    Sys.interactive := true;
    Logs.info (fun m -> m "Setup complete");
    {
      stdout = Buffer.contents stdout_buff;
      stderr = Buffer.contents stderr_buff;
    }

  (** {3 Output Helpers} *)

  let stdout_buff = Buffer.create 100
  let stderr_buff = Buffer.create 100

  let buff_opt b =
    match String.trim (Buffer.contents b) with "" -> None | s -> Some s

  let string_opt s = match String.trim s with "" -> None | s -> Some s

  let loc = function
    | Syntaxerr.Error x -> Some (Syntaxerr.location_of_error x)
    | Lexer.Error (_, loc)
    | Typecore.Error (loc, _, _)
    | Typetexp.Error (loc, _, _)
    | Typeclass.Error (loc, _, _)
    | Typemod.Error (loc, _, _)
    | Typedecl.Error (loc, _)
    | Translcore.Error (loc, _)
    | Translclass.Error (loc, _)
    | Translmod.Error (loc, _) ->
        Some loc
    | _ -> None

  (** {3 Phrase Execution}

      Executes OCaml phrases in an environment, capturing all output.
      Handles parsing, PPX preprocessing, and execution with error reporting. *)

  let execute_in_env env phrase =
    let code_buff = Buffer.create 100 in
    let res_buff = Buffer.create 100 in
    let pp_code = Format.formatter_of_buffer code_buff in
    let pp_result = Format.formatter_of_buffer res_buff in
    let highlighted = ref None in
    let set_highlight loc =
      let _file1, line1, col1 = Location.get_pos_info loc.Location.loc_start in
      let _file2, line2, col2 = Location.get_pos_info loc.Location.loc_end in
      highlighted := Some Toplevel_api_gen.{ line1; col1; line2; col2 }
    in
    Buffer.clear code_buff;
    Buffer.clear res_buff;
    Buffer.clear stderr_buff;
    Buffer.clear stdout_buff;
    let phrase =
      let l = String.length phrase in
      if l >= 2 && String.sub phrase (l - 2) 2 = ";;" then phrase
      else phrase ^ ";;"
    in
    let o, () =
      Environment.with_env env (fun () ->
        S.capture
          (fun () ->
            let lb = Lexing.from_function (refill_lexbuf phrase (ref 0) (Some pp_code)) in
            (try
               while true do
                 try
                   let phr = !Toploop.parse_toplevel_phrase lb in
                   let phr = JsooTopPpx.preprocess_phrase phr in
                   ignore (Toploop.execute_phrase true pp_result phr : bool)
                 with
                 | End_of_file -> raise End_of_file
                 | x ->
                     (match loc x with Some l -> set_highlight l | None -> ());
                     Errors.report_error Format.err_formatter x
               done
             with End_of_file -> ());
            flush_all ())
          ())
    in
    let mime_vals = Mime_printer.get () in
    Format.pp_print_flush pp_code ();
    Format.pp_print_flush pp_result ();
    Toplevel_api_gen.
      {
        stdout = string_opt o.stdout;
        stderr = string_opt o.stderr;
        sharp_ppf = buff_opt code_buff;
        caml_ppf = buff_opt res_buff;
        highlight = !highlighted;
        mime_vals;
      }

  (** {3 Incremental Phrase Execution}

      Executes OCaml phrases incrementally, calling a callback after each
      phrase with its output and location. *)

  type phrase_output = {
    loc : int;
    caml_ppf : string option;
    mime_vals : Toplevel_api_gen.mime_val list;
  }

  let execute_in_env_incremental env phrase ~on_phrase_output =
    let code_buff = Buffer.create 100 in
    let res_buff = Buffer.create 100 in
    let pp_code = Format.formatter_of_buffer code_buff in
    let pp_result = Format.formatter_of_buffer res_buff in
    let highlighted = ref None in
    let set_highlight loc =
      let _file1, line1, col1 = Location.get_pos_info loc.Location.loc_start in
      let _file2, line2, col2 = Location.get_pos_info loc.Location.loc_end in
      highlighted := Some Toplevel_api_gen.{ line1; col1; line2; col2 }
    in
    Buffer.clear code_buff;
    Buffer.clear res_buff;
    Buffer.clear stderr_buff;
    Buffer.clear stdout_buff;
    let phrase =
      let l = String.length phrase in
      if l >= 2 && String.sub phrase (l - 2) 2 = ";;" then phrase
      else phrase ^ ";;"
    in
    let o, () =
      Environment.with_env env (fun () ->
        S.capture
          (fun () ->
            let lb = Lexing.from_function (refill_lexbuf phrase (ref 0) (Some pp_code)) in
            (try
               while true do
                 try
                   let phr = !Toploop.parse_toplevel_phrase lb in
                   let phr = JsooTopPpx.preprocess_phrase phr in
                   ignore (Toploop.execute_phrase true pp_result phr : bool);
                   (* Get location from phrase AST *)
                   let loc = match phr with
                     | Parsetree.Ptop_def ({ pstr_loc; _ } :: _) ->
                         pstr_loc.loc_end.pos_cnum
                     | Parsetree.Ptop_dir { pdir_loc; _ } ->
                         pdir_loc.loc_end.pos_cnum
                     | _ -> lb.lex_curr_p.pos_cnum
                   in
                   (* Flush and get current output *)
                   Format.pp_print_flush pp_result ();
                   let caml_ppf = buff_opt res_buff in
                   let mime_vals = Mime_printer.get () in
                   (* Call callback with phrase output *)
                   on_phrase_output { loc; caml_ppf; mime_vals };
                   (* Clear for next phrase *)
                   Buffer.clear res_buff
                 with
                 | End_of_file -> raise End_of_file
                 | x ->
                     (match loc x with Some l -> set_highlight l | None -> ());
                     Errors.report_error Format.err_formatter x
               done
             with End_of_file -> ());
            flush_all ())
          ())
    in
    (* Get any remaining mime_vals (shouldn't be any after last callback) *)
    let mime_vals = Mime_printer.get () in
    Format.pp_print_flush pp_code ();
    Format.pp_print_flush pp_result ();
    Toplevel_api_gen.
      {
        stdout = string_opt o.stdout;
        stderr = string_opt o.stderr;
        sharp_ppf = buff_opt code_buff;
        caml_ppf = buff_opt res_buff;
        highlight = !highlighted;
        mime_vals;
      }

  (** {3 Dynamic CMI Loading}

      Handles loading .cmi files on demand for packages that weren't
      compiled into the worker. *)

  let filename_of_module unit_name =
    Printf.sprintf "%s.cmi" (String.uncapitalize_ascii unit_name)

  let get_dirs () =
#if OCAML_VERSION >= (5, 2, 0)
    let { Load_path.visible; hidden } = Load_path.get_paths () in
    visible @ hidden
#else
    Load_path.get_paths ()
#endif

  let reset_dirs () =
    Ocaml_utils.Directory_content_cache.clear ();
    let open Ocaml_utils.Load_path in
    let dirs = get_dirs () in
    reset ();
#if OCAML_VERSION >= (5, 2, 0)
    List.iter (fun p -> prepend_dir (Dir.create ~hidden:false p)) dirs
#else
    List.iter (fun p -> prepend_dir (Dir.create p)) dirs
#endif

  let reset_dirs_comp () =
    let open Load_path in
    let dirs = get_dirs () in
    reset ();
#if OCAML_VERSION >= (5, 2, 0)
    List.iter (fun p -> prepend_dir (Dir.create ~hidden:false p)) dirs
#else
    List.iter (fun p -> prepend_dir (Dir.create p)) dirs
#endif

  let add_dynamic_cmis dcs =
    let fetch filename =
      let url = Filename.concat dcs.Toplevel_api_gen.dcs_url filename in
      S.async_get url
    in
    let fetch_sync filename =
      let url = Filename.concat dcs.Toplevel_api_gen.dcs_url filename in
      S.sync_get url
    in
    let path =
      match !path with Some p -> p | None -> failwith "Path not set"
    in
    let ( let* ) = Lwt.bind in
    let* () =
      Logs.info (fun m -> m "Adding toplevel modules for dynamic cmis from %s" dcs.dcs_url);
      Logs.info (fun m -> m "  toplevel modules: %s"
        (String.concat ", " dcs.dcs_toplevel_modules));
      Lwt_list.iter_p
        (fun name ->
          let filename = filename_of_module name in
          let* r = fetch (filename_of_module name) in
          let () =
            match r with
            | Ok content -> (
                let name = Filename.(concat path filename) in
                try S.create_file ~name ~content with _ -> ())
            | Error _ -> ()
          in
          Lwt.return ())
        dcs.dcs_toplevel_modules
    in

#if OCAML_VERSION >= (5, 2, 0)
    let new_load ~s ~old_loader ~allow_hidden ~unit_name =
#else
    let new_load ~s ~old_loader ~unit_name =
#endif
      (* Logs.info (fun m -> m "%s Loading: %s" s unit_name); *)
      let filename = filename_of_module unit_name in

      let fs_name = Filename.(concat path filename) in
      (* Check if it's already been downloaded. This will be the
         case for all toplevel cmis. Also check whether we're supposed
         to handle this cmi *)
      (* if Sys.file_exists fs_name
      then Logs.info (fun m -> m "Found: %s" fs_name)
      else Logs.info (fun m -> m "No sign of %s locally" fs_name); *)
      if
        (not (Sys.file_exists fs_name))
        && List.exists
             (fun prefix -> String.starts_with ~prefix filename)
             dcs.dcs_file_prefixes
      then (
        Logs.info (fun m -> m "Fetching %s\n%!" filename);
        match fetch_sync filename with
        | Some x ->
            (try S.create_file ~name:fs_name ~content:x with _ -> ());
            (* At this point we need to tell merlin that the dir contents
                 have changed *)
            if s = "merl" then reset_dirs () else reset_dirs_comp ()
        | None ->
            Printf.eprintf "Warning: Expected to find cmi at: %s\n%!"
              (Filename.concat dcs.Toplevel_api_gen.dcs_url filename));
      if s = "merl" then reset_dirs () else reset_dirs_comp ();
#if OCAML_VERSION >= (5, 2, 0)
      old_loader ~allow_hidden ~unit_name
#else
      old_loader ~unit_name
#endif
    in
    let furl = "file://" in
    let l = String.length furl in
    let () =
      if String.length dcs.dcs_url > l && String.sub dcs.dcs_url 0 l = furl then
        let path = String.sub dcs.dcs_url l (String.length dcs.dcs_url - l) in
        Topdirs.dir_directory path
      else
        let open Persistent_env.Persistent_signature in
        let old_loader = !load in
        load := new_load ~s:"comp" ~old_loader;

        let open Ocaml_typing.Persistent_env.Persistent_signature in
        let old_loader = !load in
        load := new_load ~s:"merl" ~old_loader
    in
    Lwt.return ()

  (** {3 RPC Handlers}

      Functions that implement the toplevel RPC API. Each function returns
      results in the [IdlM.ErrM] monad. *)

  let init (init_libs : Toplevel_api_gen.init_config) =
    Lwt.catch
      (fun () ->
        Logs.info (fun m -> m "init()");
        path := Some S.path;

        let findlib_path = Option.value ~default:"findlib_index" init_libs.findlib_index in
        findlib_v := Some (S.findlib_init findlib_path);

        let stdlib_dcs =
          match init_libs.stdlib_dcs with
          | Some dcs -> dcs
          | None -> "lib/ocaml/dynamic_cmis.json"
        in
        let* () =
          match S.get_stdlib_dcs stdlib_dcs with
          | [ dcs ] -> add_dynamic_cmis dcs
          | _ -> Lwt.return ()
        in
        Clflags.no_check_prims := true;

        requires := init_libs.findlib_requires;
        functions := Some [];
        execution_allowed := init_libs.execute;

        (* Set up the toplevel environment *)
        Logs.info (fun m -> m "init() finished");

        Lwt.return (Ok ()))
      (fun e ->
        Lwt.return
          (Error (Toplevel_api_gen.InternalError (Printexc.to_string e))))

  let setup env_id =
    Lwt.catch
      (fun () ->
        let env = resolve_env env_id in
        Logs.info (fun m -> m "setup() for env %s..." (Environment.id env));

        if Environment.is_setup env then (
          Logs.info (fun m -> m "setup() already done for env %s" (Environment.id env));
          Lwt.return
            (Ok
               Toplevel_api_gen.
                 {
                   stdout = None;
                   stderr = Some "Environment already set up";
                   sharp_ppf = None;
                   caml_ppf = None;
                   highlight = None;
                   mime_vals = [];
                 }))
        else
          let o =
            Environment.with_env env (fun () ->
              try
                match !functions with
                | Some l -> setup l ()
                | None -> failwith "Error: toplevel has not been initialised"
              with
              | Persistent_env.Error e ->
                  Persistent_env.report_error Format.err_formatter e;
                  let err = Format.asprintf "%a" Persistent_env.report_error e in
                  failwith ("Error: " ^ err)
              | Env.Error _ as exn ->
                  Location.report_exception Format.err_formatter exn;
                  let err = Format.asprintf "%a" Location.report_exception exn in
                  failwith ("Error: " ^ err))
          in

          let* dcs =
            match !findlib_v with
            | Some v ->
              let* v = v in
              (* Store the resolved findlib value for use by #require directive *)
              findlib_resolved := Some v;
              (* Register our custom #require directive that uses findlibish *)
              register_require_directive ();
              Lwt.return (S.require (not !execution_allowed) v !requires)
            | None -> Lwt.return []
          in

          let* () = Lwt_list.iter_p add_dynamic_cmis dcs in

          Environment.mark_setup env;
          Logs.info (fun m -> m "setup() finished for env %s" (Environment.id env));

          Lwt.return
            (Ok
               Toplevel_api_gen.
                 {
                   stdout = string_opt o.stdout;
                   stderr = string_opt o.stderr;
                   sharp_ppf = None;
                   caml_ppf = None;
                   highlight = None;
                   mime_vals = [];
                 }))
      (fun e ->
        Lwt.return
          (Error (Toplevel_api_gen.InternalError (Printexc.to_string e))))

  let handle_toplevel env stripped =
    if String.length stripped < 2 || stripped.[0] <> '#' || stripped.[1] <> ' '
    then (
      Printf.eprintf
        "Warning, ignoring toplevel block without a leading '# '.\n";
      IdlM.ErrM.return
        { Toplevel_api_gen.script = stripped; mime_vals = []; parts = [] })
    else
      let s = String.sub stripped 2 (String.length stripped - 2) in
      let list = Ocamltop.parse_toplevel s in
      let buf = Buffer.create 1024 in
      let mime_vals =
        List.fold_left
          (fun acc (phr, _junk, _output) ->
            let new_output = execute_in_env env phr in
            Printf.bprintf buf "# %s\n" phr;
            let r =
              Option.to_list new_output.stdout
              @ Option.to_list new_output.stderr
              @ Option.to_list new_output.caml_ppf
            in
            let r =
              List.concat_map (fun l -> Astring.String.cuts ~sep:"\n" l) r
            in
            List.iter (fun x -> Printf.bprintf buf "  %s\n" x) r;
            let mime_vals = new_output.mime_vals in
            acc @ mime_vals)
          [] list
      in
      let content_txt = Buffer.contents buf in
      let content_txt =
        String.sub content_txt 0 (String.length content_txt - 1)
      in
      let result =
        { Toplevel_api_gen.script = content_txt; mime_vals; parts = [] }
      in
      IdlM.ErrM.return result

  let exec_toplevel env_id (phrase : string) =
    let env = resolve_env env_id in
    try handle_toplevel env phrase
    with e ->
      Logs.info (fun m -> m "Error: %s" (Printexc.to_string e));
      IdlM.ErrM.return_err
        (Toplevel_api_gen.InternalError (Printexc.to_string e))

  let execute env_id (phrase : string) =
    Logs.info (fun m -> m "execute() for env_id=%s" env_id);
    let env = resolve_env env_id in
    let result = execute_in_env env phrase in
    Logs.info (fun m -> m "execute() done for env_id=%s" env_id);
    IdlM.ErrM.return result

  let execute_incremental env_id (phrase : string) ~on_phrase_output =
    Logs.info (fun m -> m "execute_incremental() for env_id=%s" env_id);
    let env = resolve_env env_id in
    let result = execute_in_env_incremental env phrase ~on_phrase_output in
    Logs.info (fun m -> m "execute_incremental() done for env_id=%s" env_id);
    IdlM.ErrM.return result

  (** {3 Merlin Integration}

      Code intelligence features powered by Merlin: completion, type info,
      error diagnostics. *)

  let config () =
    let path =
      match !path with Some p -> p | None -> failwith "Path not set"
    in
    let initial = Merlin_kernel.Mconfig.initial in
    { initial with merlin = { initial.merlin with stdlib = Some path } }

  let make_pipeline source = Merlin_kernel.Mpipeline.make (config ()) source

  let wdispatch source query =
    let pipeline = make_pipeline source in
    Merlin_kernel.Mpipeline.with_pipeline pipeline @@ fun () ->
    Query_commands.dispatch pipeline query

  (** Completion prefix extraction, adapted from ocaml-lsp-server. *)
  module Completion = struct
    open Merlin_utils
    open Std
    open Merlin_kernel

    (* Prefixing code from ocaml-lsp-server *)
    let rfindi =
      let rec loop s ~f i =
        if i < 0 then None
        else if f (String.unsafe_get s i) then Some i
        else loop s ~f (i - 1)
      in
      fun ?from s ~f ->
        let from =
          let len = String.length s in
          match from with
          | None -> len - 1
          | Some i ->
              if i > len - 1 then
                raise @@ Invalid_argument "rfindi: invalid from"
              else i
        in
        loop s ~f from

    let lsplit2 s ~on =
      match String.index_opt s on with
      | None -> None
      | Some i ->
          let open StdLabels.String in
          Some (sub s ~pos:0 ~len:i, sub s ~pos:(i + 1) ~len:(length s - i - 1))

    (** @see <https://ocaml.org/manual/lex.html> reference *)
    let prefix_of_position ?(short_path = false) source position =
      match Msource.text source with
      | "" -> ""
      | text ->
          let from =
            let (`Offset index) = Msource.get_offset source position in
            min (String.length text - 1) (index - 1)
          in
          let pos =
            let should_terminate = ref false in
            let has_seen_dot = ref false in
            let is_prefix_char c =
              if !should_terminate then false
              else
                match c with
                | 'a' .. 'z'
                | 'A' .. 'Z'
                | '0' .. '9'
                | '\'' | '_'
                (* Infix function characters *)
                | '$' | '&' | '*' | '+' | '-' | '/' | '=' | '>' | '@' | '^'
                | '!' | '?' | '%' | '<' | ':' | '~' | '#' ->
                    true
                | '`' ->
                    if !has_seen_dot then false
                    else (
                      should_terminate := true;
                      true)
                | '.' ->
                    has_seen_dot := true;
                    not short_path
                | _ -> false
            in
            rfindi text ~from ~f:(fun c -> not (is_prefix_char c))
          in
          let pos = match pos with None -> 0 | Some pos -> pos + 1 in
          let len = from - pos + 1 in
          let reconstructed_prefix = StdLabels.String.sub text ~pos ~len in
          (* if we reconstructed [~f:ignore] or [?f:ignore], we should take only
             [ignore], so: *)
          if
            String.is_prefixed ~by:"~" reconstructed_prefix
            || String.is_prefixed ~by:"?" reconstructed_prefix
          then
            match lsplit2 reconstructed_prefix ~on:':' with
            | Some (_, s) -> s
            | None -> reconstructed_prefix
          else reconstructed_prefix

    let at_pos source position =
      let prefix = prefix_of_position source position in
      let (`Offset to_) = Msource.get_offset source position in
      let from =
        to_
        - String.length (prefix_of_position ~short_path:true source position)
      in
      if prefix = "" then None
      else
        let query =
          Query_protocol.Complete_prefix (prefix, position, [], true, true)
        in
        Some (from, to_, wdispatch source query)
  end

  let complete_prefix env_id id deps is_toplevel source position =
    let _env = resolve_env env_id in  (* Reserved for future use *)
    try
      Logs.info (fun m -> m "completing for id: %s" (match id with Some x -> x | None -> "(none)"));

      let line1, src = mangle_toplevel is_toplevel source deps in
      Logs.info (fun m -> m "line1: '%s' (length: %d)" line1 (String.length line1));
      Logs.info (fun m -> m "src: '%s' (length: %d)" src (String.length src));
      let src = line1 ^ src in
      let source = Merlin_kernel.Msource.make src in
      let map_kind :
          [ `Value
          | `Constructor
          | `Variant
          | `Label
          | `Module
          | `Modtype
          | `Type
          | `MethodCall
          | `Keyword ] ->
          Toplevel_api_gen.kind_ty = function
        | `Value -> Value
        | `Constructor -> Constructor
        | `Variant -> Variant
        | `Label -> Label
        | `Module -> Module
        | `Modtype -> Modtype
        | `Type -> Type
        | `MethodCall -> MethodCall
        | `Keyword -> Keyword
      in
      let position =
        match position with
        | Toplevel_api_gen.Start -> `Offset (String.length line1)
        | Offset x -> `Offset (x + String.length line1)
        | Logical (x, y) -> `Logical (x + 1, y)
        | End -> `End
      in

      (match position with
      | `Offset x ->
          let first_char = String.sub src (x-1) 1 in
          Logs.info (fun m -> m "complete after offset: %s" first_char)
      | _ -> ());

      match Completion.at_pos source position with
      | Some (from, to_, compl) ->
          let entries =
            List.map
              (fun (entry : Query_protocol.Compl.entry) ->
                {
                  Toplevel_api_gen.name = entry.name;
                  kind = map_kind entry.kind;
                  desc = entry.desc;
                  info = entry.info;
                  deprecated = entry.deprecated;
                })
              compl.entries
          in
          let l1l = String.length line1 in
          IdlM.ErrM.return { Toplevel_api_gen.from = from - l1l; to_ = to_ - l1l; entries }
      | None ->
          IdlM.ErrM.return { Toplevel_api_gen.from = 0; to_ = 0; entries = [] }
    with e ->
      Logs.info (fun m -> m "Error: %s" (Printexc.to_string e));
      IdlM.ErrM.return_err
        (Toplevel_api_gen.InternalError (Printexc.to_string e))

  let add_cmi execution_env id deps source =
    Logs.info (fun m -> m "add_cmi");
    let dep_modules = List.map modname_of_id deps in
    let loc = Location.none in
    let path =
      match !path with Some p -> p | None -> failwith "Path not set"
    in
    let filename = modname_of_id id |> String.uncapitalize_ascii in
    let prefix = Printf.sprintf "%s/%s" path filename in
    let filename = Printf.sprintf "%s.ml" prefix in
    Logs.info (fun m -> m "prefix: %s" prefix);
    let oc = open_out filename in
    Printf.fprintf oc "%s" source;
    close_out oc;
    (try Sys.remove (prefix ^ ".cmi") with Sys_error _ -> ());
#if OCAML_VERSION >= (5, 3, 0)
    let unit_info = Unit_info.make ~source_file:filename Impl prefix in
#elif OCAML_VERSION >= (5, 2, 0)
    let unit_info = Unit_info.make ~source_file:filename prefix in
#endif
    try
      let store = Local_store.fresh () in
      Local_store.with_store store (fun () ->
          Local_store.reset ();
          let env =
#if OCAML_VERSION < (5, 0, 0)
            Typemod.initial_env ~loc ~safe_string:true
              ~initially_opened_module:(Some "Stdlib")
              ~open_implicit_modules:dep_modules
#else
            Typemod.initial_env ~loc ~initially_opened_module:(Some "Stdlib")
              ~open_implicit_modules:dep_modules
#endif
          in
          let lexbuf = Lexing.from_string source in
          let ast = Parse.implementation lexbuf in
          Logs.info (fun m -> m "About to type_implementation");
#if OCAML_VERSION >= (5, 2, 0)
          let _ = Typemod.type_implementation unit_info env ast in
#else
          let modulename = String.capitalize_ascii (Filename.basename prefix) in
          let _ = Typemod.type_implementation filename prefix modulename env ast in
#endif
          let b = Sys.file_exists (prefix ^ ".cmi") in
          Environment.remove_failed_cell execution_env id;
          Logs.info (fun m -> m "file_exists: %s = %b" (prefix ^ ".cmi") b));
      Ocaml_typing.Cmi_cache.clear ()
    with
    | Env.Error _ as exn ->
        Logs.err (fun m -> m "Env.Error: %a" Location.report_exception exn);
        Environment.add_failed_cell execution_env id;
        ()
    | exn ->
        let s = Printexc.to_string exn in
        Logs.err (fun m -> m "Error in add_cmi: %s" s);
        Logs.err (fun m -> m "Backtrace: %s" (Printexc.get_backtrace ()));
        let ppf = Format.err_formatter in
        let _ = Location.report_exception ppf exn in
        Environment.add_failed_cell execution_env id;
        ()

  let map_pos line1 pos =
    (* Only subtract line number when there's actually a prepended line *)
    let line_offset = if line1 = "" then 0 else 1 in
    Lexing.
      {
        pos with
        pos_bol = pos.pos_bol - String.length line1;
        pos_lnum = pos.pos_lnum - line_offset;
        pos_cnum = pos.pos_cnum - String.length line1;
      }

  let map_loc line1 (loc : Ocaml_parsing.Location.t) =
    {
      loc with
      Ocaml_utils.Warnings.loc_start = map_pos line1 loc.loc_start;
      Ocaml_utils.Warnings.loc_end = map_pos line1 loc.loc_end;
    }

  let query_errors env_id id deps is_toplevel orig_source =
    let execution_env = resolve_env env_id in
    try
      let deps =
        List.filter (fun dep -> not (Environment.is_cell_failed execution_env dep)) deps
      in
      let line1, src = mangle_toplevel is_toplevel orig_source deps in
      let full_source = line1 ^ src in
      let source = Merlin_kernel.Msource.make full_source in
      let query =
        Query_protocol.Errors { lexing = true; parsing = true; typing = true }
      in
      let errors =
        wdispatch source query
        |> StdLabels.List.filter_map
             ~f:(fun
                 (Ocaml_parsing.Location.{ kind; main = _; sub; source; _ } as
                  error)
               ->
               let of_sub sub =
                 Ocaml_parsing.Location.print_sub_msg Format.str_formatter sub;
                 String.trim (Format.flush_str_formatter ())
               in
               let loc =
                 map_loc line1 (Ocaml_parsing.Location.loc_of_report error)
               in
               let main =
                 Format.asprintf "@[%a@]" Ocaml_parsing.Location.print_main
                   error
                 |> String.trim
               in
               if loc.loc_start.pos_lnum = 0 then None
               else
                 Some
                   {
                     Toplevel_api_gen.kind;
                     loc;
                     main;
                     sub = StdLabels.List.map ~f:of_sub sub;
                     source;
                   })
      in
      (* Only track cell CMIs when id is provided (notebook mode) *)
      (match id with
       | Some cell_id ->
         if List.length errors = 0 then add_cmi execution_env cell_id deps src
         else Environment.add_failed_cell execution_env cell_id
       | None -> ());

      (* Logs.info (fun m -> m "Got to end"); *)
      IdlM.ErrM.return errors
    with e ->
      Logs.info (fun m -> m "Error: %s" (Printexc.to_string e));
      IdlM.ErrM.return_err
        (Toplevel_api_gen.InternalError (Printexc.to_string e))

  let type_enclosing env_id _id deps is_toplevel orig_source position =
    let execution_env = resolve_env env_id in
    try
      let deps =
        List.filter (fun dep -> not (Environment.is_cell_failed execution_env dep)) deps
      in
      let line1, src = mangle_toplevel is_toplevel orig_source deps in
      let src = line1 ^ src in
      let position =
        match position with
        | Toplevel_api_gen.Start -> `Start
        | Offset x -> `Offset (x + String.length line1)
        | Logical (x, y) -> `Logical (x + 1, y)
        | End -> `End
      in
      let source = Merlin_kernel.Msource.make src in
      let query = Query_protocol.Type_enclosing (None, position, None) in
      let enclosing = wdispatch source query in
      let map_index_or_string = function
        | `Index i -> Toplevel_api_gen.Index i
        | `String s -> String s
      in
      let map_tail_position = function
        | `No -> Toplevel_api_gen.No
        | `Tail_position -> Tail_position
        | `Tail_call -> Tail_call
      in
      let enclosing =
        List.map
          (fun (x, y, z) ->
            (map_loc line1 x, map_index_or_string y, map_tail_position z))
          enclosing
      in
      IdlM.ErrM.return enclosing
    with e ->
      Logs.info (fun m -> m "Error: %s" (Printexc.to_string e));
      IdlM.ErrM.return_err
        (Toplevel_api_gen.InternalError (Printexc.to_string e))

  (** {3 Environment Management RPCs} *)

  let create_env env_id =
    Lwt.catch
      (fun () ->
        Logs.info (fun m -> m "create_env(%s)" env_id);
        let _env = Environment.create env_id in
        Lwt.return (Ok ()))
      (fun e ->
        Lwt.return
          (Error (Toplevel_api_gen.InternalError (Printexc.to_string e))))

  let destroy_env env_id =
    Lwt.catch
      (fun () ->
        Logs.info (fun m -> m "destroy_env(%s)" env_id);
        Environment.destroy env_id;
        Lwt.return (Ok ()))
      (fun e ->
        Lwt.return
          (Error (Toplevel_api_gen.InternalError (Printexc.to_string e))))

  let list_envs () =
    Lwt.catch
      (fun () ->
        let envs = Environment.list () in
        Logs.info (fun m -> m "list_envs() -> [%s]" (String.concat ", " envs));
        Lwt.return (Ok envs))
      (fun e ->
        Lwt.return
          (Error (Toplevel_api_gen.InternalError (Printexc.to_string e))))
end
