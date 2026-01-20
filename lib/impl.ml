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

    Handles PPX rewriter registration and application. The [Ppx_js.mapper]
    is registered by default to support js_of_ocaml syntax extensions. *)

module JsooTopPpx = struct
  open Js_of_ocaml_compiler.Stdlib

  let ppx_rewriters = ref [ (fun _ -> Ppx_js.mapper) ]

  let () =
    Ast_mapper.register_function :=
      fun _ f -> ppx_rewriters := f :: !ppx_rewriters

  let preprocess_structure str =
    let open Ast_mapper in
    List.fold_right !ppx_rewriters ~init:str ~f:(fun ppx_rewriter str ->
        let mapper = ppx_rewriter [] in
        mapper.structure mapper str)

  let preprocess_signature str =
    let open Ast_mapper in
    List.fold_right !ppx_rewriters ~init:str ~f:(fun ppx_rewriter str ->
        let mapper = ppx_rewriter [] in
        mapper.signature mapper str)

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
  (** {3 State} *)

  let functions : (unit -> unit) list option ref = ref None
  let requires : string list ref = ref []
  let path : string option ref = ref None
  let findlib_v : S.findlib_t Lwt.t option ref = ref None
  let execution_allowed = ref true

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

  (** {3 Phrase Execution} *)

  let execute printval ?pp_code ?highlight_location pp_answer s =
    let s =
      let l = String.length s in
      if String.sub s (l - 2) 2 = ";;" then s else s ^ ";;"
    in
    let lb = Lexing.from_function (refill_lexbuf s (ref 0) pp_code) in
    (try
       while true do
         try
           let phr = !Toploop.parse_toplevel_phrase lb in
           let phr = JsooTopPpx.preprocess_phrase phr in
           ignore (Toploop.execute_phrase printval pp_answer phr : bool)
         with
         | End_of_file -> raise End_of_file
         | x ->
             (match highlight_location with
             | None -> ()
             | Some f -> ( match loc x with None -> () | Some loc -> f loc));
             Errors.report_error Format.err_formatter x
       done
     with End_of_file -> ());
    flush_all ()

  let execute : string -> Toplevel_api_gen.exec_result =
    let code_buff = Buffer.create 100 in
    let res_buff = Buffer.create 100 in
    let pp_code = Format.formatter_of_buffer code_buff in
    let pp_result = Format.formatter_of_buffer res_buff in
    let highlighted = ref None in
    let highlight_location loc =
      let _file1, line1, col1 = Location.get_pos_info loc.Location.loc_start in
      let _file2, line2, col2 = Location.get_pos_info loc.Location.loc_end in
      highlighted := Some Toplevel_api_gen.{ line1; col1; line2; col2 }
    in
    fun phrase ->
      Buffer.clear code_buff;
      Buffer.clear res_buff;
      Buffer.clear stderr_buff;
      Buffer.clear stdout_buff;
      let o, () =
        S.capture
          (fun () -> execute true ~pp_code ~highlight_location pp_result phrase)
          ()
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

  (** {3 Dynamic CMI Loading}

      Handles loading .cmi files on demand for packages that weren't
      compiled into the worker. *)

  let filename_of_module unit_name =
    Printf.sprintf "%s.cmi" (String.uncapitalize_ascii unit_name)

  let get_dirs () =
    let { Load_path.visible; hidden } = Load_path.get_paths () in
    visible @ hidden

  let reset_dirs () =
    Ocaml_utils.Directory_content_cache.clear ();
    let open Ocaml_utils.Load_path in
    let dirs = get_dirs () in
    reset ();
    List.iter (fun p -> prepend_dir (Dir.create ~hidden:false p)) dirs

  let reset_dirs_comp () =
    let open Load_path in
    let dirs = get_dirs () in
    reset ();
    List.iter (fun p -> prepend_dir (Dir.create ~hidden:false p)) dirs

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

    let new_load ~s ~old_loader ~allow_hidden ~unit_name =
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
            S.create_file ~name:fs_name ~content:x;
            (* At this point we need to tell merlin that the dir contents
                 have changed *)
            if s = "merl" then reset_dirs () else reset_dirs_comp ()
        | None ->
            Printf.eprintf "Warning: Expected to find cmi at: %s\n%!"
              (Filename.concat dcs.Toplevel_api_gen.dcs_url filename));
      if s = "merl" then reset_dirs () else reset_dirs_comp ();
      old_loader ~allow_hidden ~unit_name
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

        findlib_v := Some (S.findlib_init "findlib_index");

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

  let setup () =
    Lwt.catch
      (fun () ->
        Logs.info (fun m -> m "setup() ...");

        let o =
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
              failwith ("Error: " ^ err)
        in

        let* dcs =
          match !findlib_v with
          | Some v ->
            let* v = v in
            Lwt.return (S.require (not !execution_allowed) v !requires)
          | None -> Lwt.return []
        in

        let* () = Lwt_list.iter_p add_dynamic_cmis dcs in

        Logs.info (fun m -> m "setup() finished");

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

  let typecheck_phrase :
      string ->
      (Toplevel_api_gen.exec_result, Toplevel_api_gen.err) IdlM.T.resultb =
    let res_buff = Buffer.create 100 in
    let pp_result = Format.formatter_of_buffer res_buff in
    let highlighted = ref None in
    let highlight_location loc =
      let _file1, line1, col1 = Location.get_pos_info loc.Location.loc_start in
      let _file2, line2, col2 = Location.get_pos_info loc.Location.loc_end in
      highlighted := Some Toplevel_api_gen.{ line1; col1; line2; col2 }
    in
    fun phr ->
      Buffer.clear res_buff;
      Buffer.clear stderr_buff;
      Buffer.clear stdout_buff;
      try
        let lb = Lexing.from_function (refill_lexbuf phr (ref 0) None) in
        let phr = !Toploop.parse_toplevel_phrase lb in
        let phr = Toploop.preprocess_phrase pp_result phr in
        match phr with
        | Parsetree.Ptop_def sstr ->
            let oldenv = !Toploop.toplevel_env in
            Typecore.reset_delayed_checks ();
            let str, sg, sn, _, newenv =
              Typemod.type_toplevel_phrase oldenv sstr
            in
            let sg' = Typemod.Signature_names.simplify newenv sn sg in
            ignore (Includemod.signatures ~mark:true oldenv sg sg');
            Typecore.force_delayed_checks ();
            Printtyped.implementation pp_result str;
            Format.pp_print_flush pp_result ();
            Warnings.check_fatal ();
            flush_all ();
            IdlM.ErrM.return
              Toplevel_api_gen.
                {
                  stdout = buff_opt stdout_buff;
                  stderr = buff_opt stderr_buff;
                  sharp_ppf = None;
                  caml_ppf = buff_opt res_buff;
                  highlight = !highlighted;
                  mime_vals = [];
                }
        | _ -> failwith "Typechecking"
      with x ->
        (match loc x with None -> () | Some loc -> highlight_location loc);
        Errors.report_error Format.err_formatter x;
        IdlM.ErrM.return
          Toplevel_api_gen.
            {
              stdout = buff_opt stdout_buff;
              stderr = buff_opt stderr_buff;
              sharp_ppf = None;
              caml_ppf = buff_opt res_buff;
              highlight = !highlighted;
              mime_vals = [];
            }

  let handle_toplevel stripped =
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
            let new_output = execute phr in
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

  let exec_toplevel (phrase : string) =
    try handle_toplevel phrase
    with e ->
      Logs.info (fun m -> m "Error: %s" (Printexc.to_string e));
      IdlM.ErrM.return_err
        (Toplevel_api_gen.InternalError (Printexc.to_string e))

  let execute (phrase : string) =
    let result = execute phrase in
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

  module StringSet = Set.Make (String)

  let failed_cells = ref StringSet.empty

  let complete_prefix id deps is_toplevel source position =
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

  let add_cmi id deps source =
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
    let unit_info = Unit_info.make ~source_file:filename Impl prefix in
    try
      let store = Local_store.fresh () in
      Local_store.with_store store (fun () ->
          Local_store.reset ();
          let env =
            Typemod.initial_env ~loc ~initially_opened_module:(Some "Stdlib")
              ~open_implicit_modules:dep_modules
          in
          let lexbuf = Lexing.from_string source in
          let ast = Parse.implementation lexbuf in
          Logs.info (fun m -> m "About to type_implementation");
          let _ = Typemod.type_implementation unit_info env ast in
          let b = Sys.file_exists (prefix ^ ".cmi") in
          failed_cells := StringSet.remove id !failed_cells;
          Logs.info (fun m -> m "file_exists: %s = %b" (prefix ^ ".cmi") b));
      Ocaml_typing.Cmi_cache.clear ()
    with
    | Env.Error _ as exn ->
        Logs.err (fun m -> m "Env.Error: %a" Location.report_exception exn);
        failed_cells := StringSet.add id !failed_cells;
        ()
    | exn ->
        let s = Printexc.to_string exn in
        Logs.err (fun m -> m "Error in add_cmi: %s" s);
        Logs.err (fun m -> m "Backtrace: %s" (Printexc.get_backtrace ()));
        let ppf = Format.err_formatter in
        let _ = Location.report_exception ppf exn in
        failed_cells := StringSet.add id !failed_cells;
        ()

  let map_pos line1 pos =
    Lexing.
      {
        pos with
        pos_bol = pos.pos_bol - String.length line1;
        pos_lnum = pos.pos_lnum - 1;
        pos_cnum = pos.pos_cnum - String.length line1;
      }

  let map_loc line1 (loc : Ocaml_parsing.Location.t) =
    {
      loc with
      Ocaml_utils.Warnings.loc_start = map_pos line1 loc.loc_start;
      Ocaml_utils.Warnings.loc_end = map_pos line1 loc.loc_end;
    }

  let query_errors id deps is_toplevel orig_source =
    try
      let deps =
        List.filter (fun dep -> not (StringSet.mem dep !failed_cells)) deps
      in
      (* Logs.info (fun m -> m "About to mangle toplevel"); *)
      let line1, src = mangle_toplevel is_toplevel orig_source deps in
      let id = Option.get id in
      let source = Merlin_kernel.Msource.make (line1 ^ src) in
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
      if List.length errors = 0 then add_cmi id deps src
      else failed_cells := StringSet.add id !failed_cells;

      (* Logs.info (fun m -> m "Got to end"); *)
      IdlM.ErrM.return errors
    with e ->
      Logs.info (fun m -> m "Error: %s" (Printexc.to_string e));
      IdlM.ErrM.return_err
        (Toplevel_api_gen.InternalError (Printexc.to_string e))

  let type_enclosing _id deps is_toplevel orig_source position =
    try
      let deps =
        List.filter (fun dep -> not (StringSet.mem dep !failed_cells)) deps
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
end
