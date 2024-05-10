(** IDL for talking to the toplevel webworker *)

open Rpc
open Idl

let sockpath = "/tmp/js_top_worker.sock"

open Merlin_kernel
module Location = Ocaml_parsing.Location

type lexing_position = Lexing.position = {
  pos_fname: string;
  pos_lnum: int;
  pos_bol: int;
  pos_cnum: int;
} [@@deriving rpcty]

type location = Location.t = {
  loc_start: lexing_position;
  loc_end: lexing_position;
  loc_ghost: bool;
} [@@deriving rpcty]

type location_error_source = Location.error_source =
  | Lexer
  | Parser
  | Typer
  | Warning
  | Unknown
  | Env
  | Config [@@deriving rpcty]

type location_report_kind = Location.report_kind =
  | Report_error
  | Report_warning of string
  | Report_warning_as_error of string
  | Report_alert of string
  | Report_alert_as_error of string [@@deriving rpcty]

type source = string [@@deriving rpcty]

(** CMIs are provided either statically or as URLs to be downloaded on demand *)

(** Dynamic cmis are loaded from beneath the given url. In addition the
    top-level modules are specified, and prefixes for other modules. For
    example, for the OCaml standard library, a user might pass:

    {[
      { dcs_url="/static/stdlib";
        dcs_toplevel_modules=["Stdlib"];
        dcs_file_prefixes=["stdlib__"]; }
    ]}

    In which case, merlin will expect to be able to download a valid file
    from the url ["/static/stdlib/stdlib.cmi"] corresponding to the
    specified toplevel module, and it will also attempt to download any
    module with the prefix ["Stdlib__"] from the same base url, so for
    example if an attempt is made to look up the module ["Stdlib__Foo"]
    then merlin-js will attempt to download a file from the url
    ["/static/stdlib/stdlib__Foo.cmi"].
    *)

type dynamic_cmis = {
  dcs_url : string;
  dcs_toplevel_modules : string list;
  dcs_file_prefixes : string list;
}

and static_cmi = {
  sc_name : string; (* capitalised, e.g. 'Stdlib' *)
  sc_content : string;
}

and cmis = {
  static_cmis : static_cmi list;
  dynamic_cmis : dynamic_cmis option;
} [@@deriving rpcty]

type action =
  | Complete_prefix of source * Msource.position
  | Type_enclosing of source * Msource.position
  | All_errors of source
  | Add_cmis of cmis

type error = {
  kind : location_report_kind;
  loc: location;
  main : string;
  sub : string list;
  source : location_error_source;
} [@@deriving rpcty]

type error_list = error list [@@deriving rpcty]

type kind_ty =
  [ `Constructor
  | `Keyword
  | `Label
  | `MethodCall
  | `Modtype
  | `Module 
  | `Type
  | `Value
  | `Variant ]

include
  struct
    open Rpc.Types
    let _ = fun (_ : kind_ty) -> ()
    let rec typ_of_kind_ty =
      let mk tname tpreview treview =
        BoxedTag
                {
                  tname;
                  tcontents = Unit;
                  tversion = None;
                  tdescription = [];
                  tpreview;
                  treview;
                }
      in

      Variant
        ({
           vname = "kind";
           variants =
             [mk "Constructor" (function | `Constructor -> Some () | _ -> None) (function | () -> `Constructor);
              mk "Keyword" (function | `Keyword -> Some () | _ -> None) (function | () -> `Keyword);
              mk "Label" (function | `Label -> Some () | _ -> None) (function | () -> `Label);
              mk "MethodCall" (function | `MethodCall -> Some () | _ -> None) (function | () -> `MethodCall);
              mk "Modtype" (function | `Modtype -> Some () | _ -> None) (function | () -> `Modtype);
              mk "Module" (function | `Module -> Some () | _ -> None) (function | () -> `Module);
              mk "Type" (function | `Type -> Some () | _ -> None) (function | () -> `Type);
              mk "Value" (function | `Value -> Some () | _ -> None) (function | () -> `Value);
              mk "Variant" (function | `Variant -> Some () | _ -> None) (function | () -> `Variant)];
           vdefault = None;
           vversion = None;
           vconstructor =
             (fun s' ->
                fun t ->
                  let s = String.lowercase_ascii s' in
                  match s with
                  | "constructor" ->
                      Rresult.R.bind (t.tget Unit)
                        (function | () -> Rresult.R.ok `Constructor)
                  | "keyword" ->
                      Rresult.R.bind (t.tget Unit)
                        (function | () -> Rresult.R.ok `Keyword)
                  | "label" ->
                      Rresult.R.bind (t.tget Unit)
                        (function | () -> Rresult.R.ok `Label)
                  | "methodcall" ->
                      Rresult.R.bind (t.tget Unit)
                        (function | () -> Rresult.R.ok `MethodCall)
                  | "modtype" ->
                      Rresult.R.bind (t.tget Unit)
                        (function | () -> Rresult.R.ok `Modtype)
                  | "module" ->
                      Rresult.R.bind (t.tget Unit)
                        (function | () -> Rresult.R.ok `Module)
                  | "type" ->
                      Rresult.R.bind (t.tget Unit)
                        (function | () -> Rresult.R.ok `Type)
                  | "value" ->
                      Rresult.R.bind (t.tget Unit)
                        (function | () -> Rresult.R.ok `Value)
                  | "variant" ->
                      Rresult.R.bind (t.tget Unit)
                        (function | () -> Rresult.R.ok `Variant)
                  | _ ->
                      Rresult.R.error_msg
                        (Printf.sprintf "Unknown tag '%s'" s))
         } : kind_ty variant)
    and kind_ty =
      {
        name = "kind_ty";
        description = [];
        ty = typ_of_kind_ty
      }
    let _ = typ_of_kind_ty
    and _ = kind_ty
end[@@ocaml.doc "@inline"][@@merlin.hide ]


type query_protocol_compl_entry = Query_protocol.Compl.entry
include
  struct
    open Rpc.Types
    let _ = fun (_ : query_protocol_compl_entry) -> ()
    let rec query_protocol_compl_entry_name :
      (_, query_protocol_compl_entry) field =
      {
        fname = "name";
        field = typ_of_source;
        fdefault = None;
        fdescription = [];
        fversion = None;
        fget = (fun _r -> _r.name);
        fset = (fun v -> fun _s -> { _s with name = v })
      }
    and query_protocol_compl_entry_kind :
      (_, query_protocol_compl_entry) field =
      {
        fname = "kind";
        field = typ_of_kind_ty;
        fdefault = None;
        fdescription = [];
        fversion = None;
        fget = (fun _r -> _r.kind);
        fset = (fun v -> fun _s -> { _s with kind = v })
      }
    and query_protocol_compl_entry_desc :
      (_, query_protocol_compl_entry) field =
      {
        fname = "desc";
        field = typ_of_source;
        fdefault = None;
        fdescription = [];
        fversion = None;
        fget = (fun _r -> _r.desc);
        fset = (fun v -> fun _s -> { _s with desc = v })
      }
    and query_protocol_compl_entry_info :
      (_, query_protocol_compl_entry) field =
      {
        fname = "info";
        field = typ_of_source;
        fdefault = None;
        fdescription = [];
        fversion = None;
        fget = (fun _r -> _r.info);
        fset = (fun v -> fun _s -> { _s with info = v })
      }
    and query_protocol_compl_entry_deprecated :
      (_, query_protocol_compl_entry) field =
      {
        fname = "deprecated";
        field = (let open Rpc.Types in Basic Bool);
        fdefault = None;
        fdescription = [];
        fversion = None;
        fget = (fun _r -> _r.deprecated);
        fset = (fun v -> fun _s -> { _s with deprecated = v })
      }
    and typ_of_query_protocol_compl_entry =
      Struct
        ({
           fields =
             [BoxedField query_protocol_compl_entry_name;
             BoxedField query_protocol_compl_entry_kind;
             BoxedField query_protocol_compl_entry_desc;
             BoxedField query_protocol_compl_entry_info;
             BoxedField query_protocol_compl_entry_deprecated];
           sname = "query_protocol_compl_entry";
           version = None;
           constructor =
             (fun getter ->
                let open Rresult.R in
                  (getter.field_get "deprecated"
                     (let open Rpc.Types in Basic Bool))
                    >>=
                    (fun query_protocol_compl_entry_deprecated ->
                       (getter.field_get "info" typ_of_source) >>=
                         (fun query_protocol_compl_entry_info ->
                            (getter.field_get "desc" typ_of_source)
                              >>=
                              (fun query_protocol_compl_entry_desc ->
                                 (getter.field_get "kind"
                                    typ_of_kind_ty)
                                   >>=
                                   (fun query_protocol_compl_entry_kind ->
                                      (getter.field_get "name"
                                         typ_of_source)
                                        >>=
                                        (fun query_protocol_compl_entry_name
                                           ->
                                           return
                                             {
                                               Query_protocol.Compl.name =
                                                 query_protocol_compl_entry_name;
                                               kind =
                                                 query_protocol_compl_entry_kind;
                                               desc =
                                                 query_protocol_compl_entry_desc;
                                               info =
                                                 query_protocol_compl_entry_info;
                                               deprecated =
                                                 query_protocol_compl_entry_deprecated
                                             }))))))
         } : query_protocol_compl_entry structure)
    and query_protocol_compl_entry =
      {
        name = "query_protocol_compl_entry";
        description = [];
        ty = typ_of_query_protocol_compl_entry
      }
    let _ = query_protocol_compl_entry_name
    and _ = query_protocol_compl_entry_kind
    and _ = query_protocol_compl_entry_desc
    and _ = query_protocol_compl_entry_info
    and _ = query_protocol_compl_entry_deprecated
    and _ = typ_of_query_protocol_compl_entry
    and _ = query_protocol_compl_entry
  end[@@ocaml.doc "@inline"][@@merlin.hide ]


include
  struct
    open Rpc.Types
    let _ = fun (_ : Merlin_kernel.Msource.position) -> ()
    let rec typ_of_msource_position =
      Variant
        ({
           vname = "msource_position";
           variants =
             [BoxedTag
                {
                  tname = "Start";
                  tcontents = Unit;
                  tversion = None;
                  tdescription = [];
                  tpreview =
                    ((function | `Start -> Some () | _ -> None));
                  treview = ((function | () -> `Start))
                };
             BoxedTag
               {
                 tname = "Offset";
                 tcontents = ((let open Rpc.Types in Basic Int));
                 tversion = None;
                 tdescription = [];
                 tpreview =
                   ((function | `Offset a0 -> Some a0 | _ -> None));
                 treview = ((function | a0 -> `Offset a0))
               };
             BoxedTag
               {
                 tname = "Logical";
                 tcontents =
                   (Tuple
                      (((let open Rpc.Types in Basic Int)),
                        ((let open Rpc.Types in Basic Int))));
                 tversion = None;
                 tdescription = [];
                 tpreview =
                   ((function | `Logical (a0, a1) -> Some (a0, a1) | _ -> None));
                 treview =
                   ((function | (a0, a1) -> `Logical (a0, a1)))
               };
             BoxedTag
               {
                 tname = "End";
                 tcontents = Unit;
                 tversion = None;
                 tdescription = [];
                 tpreview =
                   ((function | `End -> Some () | _ -> None));
                 treview = ((function | () -> `End))
               }];
           vdefault = None;
           vversion = None;
           vconstructor =
             (fun s' ->
                fun t ->
                  let s = String.lowercase_ascii s' in
                  match s with
                  | "start" ->
                      Rresult.R.bind (t.tget Unit)
                        (function | () -> Rresult.R.ok `Start)
                  | "offset" ->
                      Rresult.R.bind
                        (t.tget (let open Rpc.Types in Basic Int))
                        (function | a0 -> Rresult.R.ok (`Offset a0))
                  | "logical" ->
                      Rresult.R.bind
                        (t.tget
                           (Tuple
                              ((let open Rpc.Types in Basic Int),
                                (let open Rpc.Types in Basic Int))))
                        (function
                         | (a0, a1) -> Rresult.R.ok (`Logical (a0, a1)))
                  | "end" ->
                      Rresult.R.bind (t.tget Unit)
                        (function | () -> Rresult.R.ok `End)
                  | _ ->
                      Rresult.R.error_msg
                        (Printf.sprintf "Unknown tag '%s'" s))
         } : Merlin_kernel.Msource.position variant)
    and msource_position =
      {
        name = "msource_position";
        description = [];
        ty = typ_of_msource_position
      }
    let _ = typ_of_msource_position
    and _ = msource_position
  end[@@ocaml.doc "@inline"][@@merlin.hide ]

type completions = {
  from: int;
  to_: int;
  entries : query_protocol_compl_entry list
} [@@deriving rpcty]

type is_tail_position =
  [ `No | `Tail_position | `Tail_call ]
  include
  struct
    open Rpc.Types
    let _ = fun (_ : is_tail_position) -> ()
    let rec typ_of_is_tail_position =
      Variant
        ({
           vname = "is_tail_position";
           variants =
             [BoxedTag
                {
                  tname = "No";
                  tcontents = Unit;
                  tversion = None;
                  tdescription = [];
                  tpreview =
                    ((function | `No -> Some () | _ -> None));
                  treview = ((function | () -> `No))
                };
             BoxedTag
               {
                 tname = "Tail_position";
                 tcontents = Unit;
                 tversion = None;
                 tdescription = [];
                 tpreview =
                   ((function | `Tail_position -> Some () | _ -> None));
                 treview = ((function | () -> `Tail_position))
               };
             BoxedTag
               {
                 tname = "Tail_call";
                 tcontents = Unit;
                 tversion = None;
                 tdescription = [];
                 tpreview =
                   ((function | `Tail_call -> Some () | _ -> None));
                 treview = ((function | () -> `Tail_call))
               }];
           vdefault = None;
           vversion = None;
           vconstructor =
             (fun s' ->
                fun t ->
                  let s = String.lowercase_ascii s' in
                  match s with
                  | "no" ->
                      Rresult.R.bind (t.tget Unit)
                        (function | () -> Rresult.R.ok `No)
                  | "tail_position" ->
                      Rresult.R.bind (t.tget Unit)
                        (function | () -> Rresult.R.ok `Tail_position)
                  | "tail_call" ->
                      Rresult.R.bind (t.tget Unit)
                        (function | () -> Rresult.R.ok `Tail_call)
                  | _ ->
                      Rresult.R.error_msg
                        (Printf.sprintf "Unknown tag '%s'" s))
         } : is_tail_position variant)
    and is_tail_position =
      {
        name = "is_tail_position";
        description = [];
        ty = typ_of_is_tail_position
      }
    let _ = typ_of_is_tail_position
    and _ = is_tail_position
  end[@@ocaml.doc "@inline"][@@merlin.hide ]

type index_or_string =
  [ `Index of int
  | `String of string ]
include
  struct
    open Rpc.Types
    let _ = fun (_ : index_or_string) -> ()
    let rec typ_of_index_or_string =
      Variant
        ({
           vname = "index_or_string";
           variants =
             [BoxedTag
                {
                  tname = "Index";
                  tcontents = ((let open Rpc.Types in Basic Int));
                  tversion = None;
                  tdescription = [];
                  tpreview =
                    ((function | `Index a0 -> Some a0 | _ -> None));
                  treview = ((function | a0 -> `Index a0))
                };
             BoxedTag
               {
                 tname = "String";
                 tcontents = ((let open Rpc.Types in Basic String));
                 tversion = None;
                 tdescription = [];
                 tpreview =
                   ((function | `String a0 -> Some a0 | _ -> None));
                 treview = ((function | a0 -> `String a0))
               }];
           vdefault = None;
           vversion = None;
           vconstructor =
             (fun s' ->
                fun t ->
                  let s = String.lowercase_ascii s' in
                  match s with
                  | "index" ->
                      Rresult.R.bind
                        (t.tget (let open Rpc.Types in Basic Int))
                        (function | a0 -> Rresult.R.ok (`Index a0))
                  | "string" ->
                      Rresult.R.bind
                        (t.tget (let open Rpc.Types in Basic String))
                        (function | a0 -> Rresult.R.ok (`String a0))
                  | _ ->
                      Rresult.R.error_msg
                        (Printf.sprintf "Unknown tag '%s'" s))
         } : index_or_string variant)
    and index_or_string =
      {
        name = "index_or_string";
        description = [];
        ty = typ_of_index_or_string
      }
    let _ = typ_of_index_or_string
    and _ = index_or_string
  end[@@ocaml.doc "@inline"][@@merlin.hide ]

type typed_enclosings = location * index_or_string * is_tail_position [@@deriving rpcty]
type typed_enclosings_list = typed_enclosings list [@@deriving rpcty]
let report_source_to_string = function
  | Location.Lexer   -> "lexer"
  | Location.Parser  -> "parser"
  | Location.Typer   -> "typer"
  | Location.Warning -> "warning" (* todo incorrect ?*)
  | Location.Unknown -> "unknown"
  | Location.Env     -> "env"
  | Location.Config  -> "config"

type highlight = { line1 : int; line2 : int; col1 : int; col2 : int }
[@@deriving rpcty]
(** An area to be highlighted *)
type encoding = Mime_printer.encoding = | Noencoding | Base64 [@@deriving rpcty]

type mime_val = Mime_printer.t = {
  mime_type : string;
  encoding : encoding;
  data : string;
}
[@@deriving rpcty]

type exec_result = {
  stdout : string option;
  stderr : string option;
  sharp_ppf : string option;
  caml_ppf : string option;
  highlight : highlight option;
  mime_vals : mime_val list;
}
[@@deriving rpcty]
(** Represents the result of executing a toplevel phrase *)

type cma = {
  url : string;  (** URL where the cma is available *)
  fn : string;  (** Name of the 'wrapping' function *)
}
[@@deriving rpcty]

type init_libs = { path : string; cmis : cmis; cmas : cma list } [@@deriving rpcty]
type err = InternalError of string [@@deriving rpcty]

module E = Idl.Error.Make (struct
  type t = err

  let t = err
  let internal_error_of e = Some (InternalError (Printexc.to_string e))
end)

let err = E.error

module Make (R : RPC) = struct
  open R

  let description =
    Interface.
      {
        name = "Toplevel";
        namespace = None;
        description =
          [ "Functions for manipulating the toplevel worker thread" ];
        version = (1, 0, 0);
      }

  let implementation = implement description
  let unit_p = Param.mk Types.unit
  let phrase_p = Param.mk Types.string
  let id_p = Param.mk Types.string
  let typecheck_result_p = Param.mk exec_result
  let exec_result_p = Param.mk exec_result

  let source_p = Param.mk source
  let position_p = Param.mk msource_position

  let completions_p = Param.mk completions
  let error_list_p = Param.mk error_list
  let typed_enclosings_p = Param.mk typed_enclosings_list

  let init_libs =
    Param.mk ~name:"init_libs"
      ~description:
        [
          "Libraries to load during the initialisation of the toplevel. ";
          "If the stdlib cmis have not been compiled into the worker this ";
          "MUST include the urls from which they may be fetched";
        ]
      init_libs

  let init =
    declare "init"
      [ "Initialise the toplevel. This must be called before any other API." ]
      (init_libs @-> returning unit_p err)

  let setup =
    declare "setup"
      [
        "Start the toplevel. Return value is the initial blurb ";
        "printed when starting a toplevel. Note that the toplevel";
        "must be initialised first.";
      ]
      (unit_p @-> returning exec_result_p err)

  let typecheck =
    declare "typecheck"
      [ "Typecheck a phrase without actually executing it." ]
      (phrase_p @-> returning typecheck_result_p err)

  let exec =
    declare "exec"
      [
        "Execute a phrase using the toplevel. The toplevel must have been";
        "Initialised first.";
      ]
      (phrase_p @-> returning exec_result_p err)

  let compile_js =
    declare "compile_js"
      [
        "Compile a phrase to javascript. The toplevel must have been";
        "Initialised first.";
      ]
      (id_p @-> phrase_p @-> returning phrase_p err)

  let complete_prefix =
    declare "complete_prefix"
      [ 
        "Complete a prefix"
      ]
      (source_p @-> position_p @-> returning completions_p err)
  
  let query_errors =
    declare "query_errors"
      [
        "Query the errors in the given source"
      ]
      (source_p @-> returning error_list_p err)

  let type_enclosing =
    declare "type_enclosing"
      [
        "Get the type of the enclosing expression"
      ]
      (source_p @-> position_p @-> returning typed_enclosings_p err)
end
