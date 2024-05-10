(* Implementation *)
open Js_top_worker_rpc
module M = Idl.IdM (* Server is synchronous *)
module IdlM = Idl.Make (M)

type captured = { stdout : string; stderr : string }

module type S = sig
  val capture : (unit -> 'a) -> unit -> captured * 'a
  val create_file : name:string -> content:string -> unit
  val sync_get : string -> string option
end

module Make (S : S) = struct
  let functions : (unit -> unit) list option ref = ref None
  let path : string option ref = ref None

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

  (* RPC function implementations *)

  (* These are all required to return the appropriate value for the API within the
     [IdlM.T] monad. The simplest way to do this is to use [IdlM.ErrM.return] for
     the success case and [IdlM.ErrM.return_err] for the failure case *)

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
    Logs.info (fun m -> m "Setting up toplevel");
    Sys.interactive := false;
    Logs.info (fun m -> m "Finished this bit 1");

    Toploop.input_name := "//toplevel//";
    Logs.info (fun m -> m "Finished this bit 2");
    let path =
      match !path with Some p -> p | None -> failwith "Path not set"
    in

    Topdirs.dir_directory path;

    List.iter Topdirs.dir_directory [
      "/Users/jonathanludlam/devel/learno/_opam/lib/note";
  "/Users/jonathanludlam/devel/learno/_opam/lib/js_of_ocaml-compiler/runtime";
"/Users/jonathanludlam/devel/learno/_opam/lib/brr";
"/Users/jonathanludlam/devel/learno/_opam/lib/note/brr";
"/Users/jonathanludlam/devel/learno/codemirror3/odoc_notebook/_build/default/mime_printer/.mime_printer.objs/byte"
    ];

    Logs.info (fun m -> m "Finished this bit 3");
    Toploop.initialize_toplevel_env ();
    Logs.info (fun m -> m "Finished this bit 4");

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

  let execute printval ?pp_code ?highlight_location pp_answer s =
    let lb = Lexing.from_function (refill_lexbuf s (ref 0) pp_code) in
    (try
       while true do
         try
           let phr = !Toploop.parse_toplevel_phrase lb in
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

  let execute :
      string ->
      (Toplevel_api_gen.exec_result, Toplevel_api_gen.err) IdlM.T.resultb =
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
      IdlM.ErrM.return
        Toplevel_api_gen.
          {
            stdout = string_opt o.stdout;
            stderr = string_opt o.stderr;
            sharp_ppf = buff_opt code_buff;
            caml_ppf = buff_opt res_buff;
            highlight = !highlighted;
            mime_vals;
          }

  let filename_of_module unit_name =
    Printf.sprintf "%s.cmi" (String.uncapitalize_ascii unit_name)

  let reset_dirs () =
    Ocaml_utils.Directory_content_cache.clear ();
    let open Ocaml_utils.Load_path in
    let dirs = get_paths () in
    reset ();
    List.iter (fun p -> prepend_dir (Dir.create p)) dirs

  let add_dynamic_cmis dcs =
    let open Ocaml_typing.Persistent_env.Persistent_signature in
    let old_loader = !load in

    let fetch filename =
      let url = Filename.concat dcs.Toplevel_api_gen.dcs_url filename in
      S.sync_get url
    in
    let path =
      match !path with Some p -> p | None -> failwith "Path not set"
    in

    List.iter
      (fun name ->
        let filename = filename_of_module name in
        match fetch (filename_of_module name) with
        | Some content ->
            let name = Filename.(concat path filename) in
            S.create_file ~name ~content
        | None -> ())
      dcs.dcs_toplevel_modules;

    let new_load ~unit_name =
      let filename = filename_of_module unit_name in

      let fs_name = Filename.(concat path filename) in
      (* Check if it's already been downloaded. This will be the
         case for all toplevel cmis. Also check whether we're supposed
         to handle this cmi *)
      (if
         (not (Sys.file_exists fs_name))
         && List.exists
              (fun prefix -> String.starts_with ~prefix filename)
              dcs.dcs_file_prefixes
       then
         match fetch filename with
         | Some x ->
             S.create_file ~name:fs_name ~content:x;
             (* At this point we need to tell merlin that the dir contents
                 have changed *)
             reset_dirs ()
         | None ->
             Printf.eprintf "Warning: Expected to find cmi at: %s\n%!"
               (Filename.concat dcs.Toplevel_api_gen.dcs_url filename));
      old_loader ~unit_name
    in
    load := new_load

  let init (init_libs : Toplevel_api_gen.init_libs) =
    try
      Logs.info (fun m -> m "init()");
      path := Some init_libs.path;

      Clflags.no_check_prims := true;
      List.iter
        (fun { Toplevel_api_gen.sc_name; sc_content } ->
          let filename =
            Printf.sprintf "%s.cmi" (String.uncapitalize_ascii sc_name)
          in
          let name = Filename.(concat init_libs.path filename) in
          S.create_file ~name ~content:sc_content)
        init_libs.cmis.static_cmis;
      Option.iter add_dynamic_cmis init_libs.cmis.dynamic_cmis;

      (*import_scripts
          (List.map (fun cma -> cma.Toplevel_api_gen.url) init_libs.cmas);
        functions :=
          Some
            (List.map
               (fun func_name ->
                 Logs.info (fun m -> m "Function: %s" func_name);
                 let func = Js.Unsafe.js_expr func_name in
                 fun () ->
                   Js.Unsafe.fun_call func [| Js.Unsafe.inject Dom_html.window |])
               (List.map (fun cma -> cma.Toplevel_api_gen.fn) init_libs.cmas)); *)
      functions := Some [];
      Logs.info (fun m -> m "init() finished");

      IdlM.ErrM.return ()
    with e ->
      IdlM.ErrM.return_err
        (Toplevel_api_gen.InternalError (Printexc.to_string e))

  let setup () =
    try
      Logs.info (fun m -> m "setup()");

      let o =
        match !functions with
        | Some l -> setup l ()
        | None -> failwith "Error: toplevel has not been initialised"
      in
      IdlM.ErrM.return
        Toplevel_api_gen.
          {
            stdout = string_opt o.stdout;
            stderr = string_opt o.stderr;
            sharp_ppf = None;
            caml_ppf = None;
            highlight = None;
            mime_vals = [];
          }
    with e ->
      IdlM.ErrM.return_err
        (Toplevel_api_gen.InternalError (Printexc.to_string e))

  let complete _phrase = failwith "Not implemented"

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
            ignore (Includemod.signatures ~mark:Mark_positive oldenv sg sg');
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

  let split_primitives p =
    let len = String.length p in
    let rec split beg cur =
      if cur >= len then []
      else if Char.equal p.[cur] '\000' then
        String.sub p beg (cur - beg) :: split (cur + 1) (cur + 1)
      else split beg (cur + 1)
    in
    Array.of_list (split 0 0)

  let compile_js id prog =
    let open Js_of_ocaml_compiler in
    let open Js_of_ocaml_compiler.Stdlib in
    try
      let str = Printf.sprintf "let _ = Mime_printer.id := \"%s\"\n%s" id prog in
      let l = Lexing.from_string str in
      let phr = Parse.toplevel_phrase l in
      Typecore.reset_delayed_checks ();
      Env.reset_cache_toplevel ();
      let oldenv = !Toploop.toplevel_env in
      (* let oldenv = Compmisc.initial_env() in *)
      match phr with
      | Ptop_def sstr ->
          let str, sg, sn, _shape, newenv =
            try Typemod.type_toplevel_phrase oldenv sstr
            with Env.Error e ->
              Env.report_error Format.err_formatter e;
              exit 1
          in
          let sg' = Typemod.Signature_names.simplify newenv sn sg in
          ignore (Includemod.signatures ~mark:Mark_positive oldenv sg sg');
          Typecore.force_delayed_checks ();
          let lam = Translmod.transl_toplevel_definition str in
          let slam = Simplif.simplify_lambda lam in
          let init_code, fun_code = Bytegen.compile_phrase slam in
          let code, reloc, _events = Emitcode.to_memory init_code fun_code in
          Toploop.toplevel_env := newenv;
          (* let prims = split_primitives (Symtable.data_primitive_names ()) in *)
          let b = Buffer.create 100 in
          let cmo =
            Cmo_format.
              {
                cu_name = "test";
                cu_pos = 0;
                cu_codesize = Misc.LongString.length code;
                cu_reloc = reloc;
                cu_imports = [];
                cu_required_globals = [];
                cu_primitives = [];
                cu_force_link = false;
                cu_debug = 0;
                cu_debugsize = 0;
              }
          in
          let fmt = Pretty_print.to_buffer b in
          (* Symtable.patch_object code reloc;
             Symtable.check_global_initialized reloc;
             Symtable.update_global_table(); *)
          let oc = open_out "/tmp/test.cmo" in
          Misc.LongString.output oc code 0 (Misc.LongString.length code);

          (* let code = String.init (Misc.LongString.length code) ~f:(fun i -> Misc.LongString.get code i) in *)
          close_out oc;
          Driver.configure fmt;
          let ic = open_in "/tmp/test.cmo" in
          let p = Parse_bytecode.from_cmo cmo ic in
          Driver.f' ~standalone:false ~wrap_with_fun:(`Named id) ~linkall:false
            fmt p.debug p.code;
          Format.(pp_print_flush std_formatter ());
          Format.(pp_print_flush err_formatter ());
          flush stdout;
          flush stderr;
          let js = Buffer.contents b in
          IdlM.ErrM.return js
      | _ -> IdlM.ErrM.return_err (Toplevel_api_gen.InternalError "Parse error")
    with e -> IdlM.ErrM.return ("Exception: %s" ^ Printexc.to_string e)

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

  let complete_prefix source position =
    let source = Merlin_kernel.Msource.make source in
    match Completion.at_pos source position with
    | Some (from, to_, compl) ->
        let entries = compl.entries in
        IdlM.ErrM.return { Toplevel_api_gen.from; to_; entries }
    | None ->
        IdlM.ErrM.return { Toplevel_api_gen.from = 0; to_ = 0; entries = [] }

  let query_errors source =
    let source = Merlin_kernel.Msource.make source in
    let query =
      Query_protocol.Errors { lexing = true; parsing = true; typing = true }
    in
    let errors =
      wdispatch source query
      |> StdLabels.List.map
           ~f:(fun
               (Ocaml_parsing.Location.{ kind; main = _; sub; source } as error)
             ->
             let of_sub sub =
               Ocaml_parsing.Location.print_sub_msg Format.str_formatter sub;
               String.trim (Format.flush_str_formatter ())
             in
             let loc = Ocaml_parsing.Location.loc_of_report error in
             let main =
               Format.asprintf "@[%a@]" Ocaml_parsing.Location.print_main error
               |> String.trim
             in
             {
               Toplevel_api_gen.kind;
               loc;
               main;
               sub = StdLabels.List.map ~f:of_sub sub;
               source;
             })
    in
    IdlM.ErrM.return errors

  let type_enclosing source position =
    let source = Merlin_kernel.Msource.make source in
    let query = Query_protocol.Type_enclosing (None, position, None) in
    let enclosing = wdispatch source query in
    IdlM.ErrM.return enclosing
end
