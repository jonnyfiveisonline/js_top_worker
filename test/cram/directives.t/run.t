Comprehensive test suite for OCaml toplevel directives.
Most tests will initially FAIL - this is TDD!

References:
- OCaml Manual: https://ocaml.org/manual/5.4/toplevel.html
- Findlib: http://projects.camlcity.org/projects/dl/findlib-1.7.1/doc/ref-html/lib/Topfind.html

  $ export OCAMLRUNPARAM=b
  $ export JS_TOP_WORKER_SOCK="/tmp/js_top_worker_directives_$$.sock"
  $ WORKER_PID=$(sh ../start_worker.sh)
  $ unix_client init '{ findlib_requires:[], execute: true }'
  N
  $ unix_client setup ''
  {mime_vals:[];stderr:S(error while evaluating #enable "pretty";;
  error while evaluating #disable "shortvar";;);stdout:S(OCaml version 5.4.0
  Unknown directive enable.
  Unknown directive disable.)}

==============================================
SECTION 1: Basic Code Execution (Baseline)
==============================================

  $ unix_client exec_toplevel '' '# 1 + 2;;'
  {mime_vals:[];parts:[];script:S(# 1 + 2;;
    - : int = 3)}

  $ unix_client exec_toplevel '' '# let x = 42;;'
  {mime_vals:[];parts:[];script:S(# let x = 42;;
    val x : int = 42)}

==============================================
SECTION 2: #show Directives (Environment Query)
==============================================

Define some types and values to query:

  $ unix_client exec_toplevel '' '# type point = { x: float; y: float };;'
  {mime_vals:[];parts:[];script:S(# type point = { x: float; y: float };;
    type point = { x : float; y : float; })}

  $ unix_client exec_toplevel '' '# let origin = { x = 0.0; y = 0.0 };;'
  {mime_vals:[];parts:[];script:S(# let origin = { x = 0.0; y = 0.0 };;
    val origin : point = {x = 0.; y = 0.})}

  $ unix_client exec_toplevel '' '# module MyMod = struct type t = int let zero = 0 end;;'
  {mime_vals:[];parts:[];script:S(# module MyMod = struct type t = int let zero = 0 end;;
    module MyMod : sig type t = int val zero : int end)}

  $ unix_client exec_toplevel '' '# exception My_error of string;;'
  {mime_vals:[];parts:[];script:S(# exception My_error of string;;
    exception My_error of string)}

Test #show directive:

  $ unix_client exec_toplevel '' '# #show point;;'
  {mime_vals:[];parts:[];script:S(# #show point;;
    type point = { x : float; y : float; })}

  $ unix_client exec_toplevel '' '# #show origin;;'
  {mime_vals:[];parts:[];script:S(# #show origin;;
    val origin : point)}

  $ unix_client exec_toplevel '' '# #show MyMod;;'
  {mime_vals:[];parts:[];script:S(# #show MyMod;;
    module MyMod : sig type t = int val zero : int end)}

  $ unix_client exec_toplevel '' '# #show My_error;;'
  {mime_vals:[];parts:[];script:S(# #show My_error;;
    exception My_error of string)}

Test #show_type directive:

  $ unix_client exec_toplevel '' '# #show_type point;;'
  {mime_vals:[];parts:[];script:S(# #show_type point;;
    type point = { x : float; y : float; })}

  $ unix_client exec_toplevel '' '# #show_type list;;'
  {mime_vals:[];parts:[];script:S(# #show_type list;;
    type 'a list = [] | (::) of 'a * 'a list)}

Test #show_val directive:

  $ unix_client exec_toplevel '' '# #show_val origin;;'
  {mime_vals:[];parts:[];script:S(# #show_val origin;;
    val origin : point)}

  $ unix_client exec_toplevel '' '# #show_val List.map;;'
  {mime_vals:[];parts:[];script:S(# #show_val List.map;;
    val map : ('a -> 'b) -> 'a list -> 'b list)}

Test #show_module directive:

  $ unix_client exec_toplevel '' '# #show_module List;;'
  {mime_vals:[];parts:[];script:S(# #show_module List;;
    module List :
      sig
        type 'a t = 'a list = [] | (::) of 'a * 'a list
        val length : 'a list -> int
        val compare_lengths : 'a list -> 'b list -> int
        val compare_length_with : 'a list -> int -> int
        val is_empty : 'a list -> bool
        val cons : 'a -> 'a list -> 'a list
        val singleton : 'a -> 'a list
        val hd : 'a list -> 'a
        val tl : 'a list -> 'a list
        val nth : 'a list -> int -> 'a
        val nth_opt : 'a list -> int -> 'a option
        val rev : 'a list -> 'a list
        val init : int -> (int -> 'a) -> 'a list
        val append : 'a list -> 'a list -> 'a list
        val rev_append : 'a list -> 'a list -> 'a list
        val concat : 'a list list -> 'a list
        val flatten : 'a list list -> 'a list
        val equal : ('a -> 'a -> bool) -> 'a list -> 'a list -> bool
        val compare : ('a -> 'a -> int) -> 'a list -> 'a list -> int
        val iter : ('a -> unit) -> 'a list -> unit
        val iteri : (int -> 'a -> unit) -> 'a list -> unit
        val map : ('a -> 'b) -> 'a list -> 'b list
        val mapi : (int -> 'a -> 'b) -> 'a list -> 'b list
        val rev_map : ('a -> 'b) -> 'a list -> 'b list
        val filter_map : ('a -> 'b option) -> 'a list -> 'b list
        val concat_map : ('a -> 'b list) -> 'a list -> 'b list
        val fold_left_map :
          ('acc -> 'a -> 'acc * 'b) -> 'acc -> 'a list -> 'acc * 'b list
        val fold_left : ('acc -> 'a -> 'acc) -> 'acc -> 'a list -> 'acc
        val fold_right : ('a -> 'acc -> 'acc) -> 'a list -> 'acc -> 'acc
        val iter2 : ('a -> 'b -> unit) -> 'a list -> 'b list -> unit
        val map2 : ('a -> 'b -> 'c) -> 'a list -> 'b list -> 'c list
        val rev_map2 : ('a -> 'b -> 'c) -> 'a list -> 'b list -> 'c list
        val fold_left2 :
          ('acc -> 'a -> 'b -> 'acc) -> 'acc -> 'a list -> 'b list -> 'acc
        val fold_right2 :
          ('a -> 'b -> 'acc -> 'acc) -> 'a list -> 'b list -> 'acc -> 'acc
        val for_all : ('a -> bool) -> 'a list -> bool
        val exists : ('a -> bool) -> 'a list -> bool
        val for_all2 : ('a -> 'b -> bool) -> 'a list -> 'b list -> bool
        val exists2 : ('a -> 'b -> bool) -> 'a list -> 'b list -> bool
        val mem : 'a -> 'a list -> bool
        val memq : 'a -> 'a list -> bool
        val find : ('a -> bool) -> 'a list -> 'a
        val find_opt : ('a -> bool) -> 'a list -> 'a option
        val find_index : ('a -> bool) -> 'a list -> int option
        val find_map : ('a -> 'b option) -> 'a list -> 'b option
        val find_mapi : (int -> 'a -> 'b option) -> 'a list -> 'b option
        val filter : ('a -> bool) -> 'a list -> 'a list
        val find_all : ('a -> bool) -> 'a list -> 'a list
        val filteri : (int -> 'a -> bool) -> 'a list -> 'a list
        val take : int -> 'a list -> 'a list
        val drop : int -> 'a list -> 'a list
        val take_while : ('a -> bool) -> 'a list -> 'a list
        val drop_while : ('a -> bool) -> 'a list -> 'a list
        val partition : ('a -> bool) -> 'a list -> 'a list * 'a list
        val partition_map :
          ('a -> ('b, 'c) Either.t) -> 'a list -> 'b list * 'c list
        val assoc : 'a -> ('a * 'b) list -> 'b
        val assoc_opt : 'a -> ('a * 'b) list -> 'b option
        val assq : 'a -> ('a * 'b) list -> 'b
        val assq_opt : 'a -> ('a * 'b) list -> 'b option
        val mem_assoc : 'a -> ('a * 'b) list -> bool
        val mem_assq : 'a -> ('a * 'b) list -> bool
        val remove_assoc : 'a -> ('a * 'b) list -> ('a * 'b) list
        val remove_assq : 'a -> ('a * 'b) list -> ('a * 'b) list
        val split : ('a * 'b) list -> 'a list * 'b list
        val combine : 'a list -> 'b list -> ('a * 'b) list
        val sort : ('a -> 'a -> int) -> 'a list -> 'a list
        val stable_sort : ('a -> 'a -> int) -> 'a list -> 'a list
        val fast_sort : ('a -> 'a -> int) -> 'a list -> 'a list
        val sort_uniq : ('a -> 'a -> int) -> 'a list -> 'a list
        val merge : ('a -> 'a -> int) -> 'a list -> 'a list -> 'a list
        val to_seq : 'a list -> 'a Seq.t
        val of_seq : 'a Seq.t -> 'a list
      end)}

Test #show_exception directive:

  $ unix_client exec_toplevel '' '# #show_exception Not_found;;'
  {mime_vals:[];parts:[];script:S(# #show_exception Not_found;;
    exception Not_found)}

  $ unix_client exec_toplevel '' '# #show_exception Invalid_argument;;'
  {mime_vals:[];parts:[];script:S(# #show_exception Invalid_argument;;
    exception Invalid_argument of string)}

==============================================
SECTION 3: #print_depth and #print_length
==============================================

  $ unix_client exec_toplevel '' '# let nested = [[[[1;2;3]]]];;'
  {mime_vals:[];parts:[];script:S(# let nested = [[[[1;2;3]]]];;
    val nested : int list list list list = [[[[1; 2; 3]]]])}

Test #print_depth:

  $ unix_client exec_toplevel '' '# #print_depth 2;;'
  {mime_vals:[];parts:[];script:S(# #print_depth 2;;)}

  $ unix_client exec_toplevel '' '# nested;;'
  {mime_vals:[];parts:[];script:S(# nested;;
    - : int list list list list = [[[...]]])}

  $ unix_client exec_toplevel '' '# #print_depth 100;;'
  {mime_vals:[];parts:[];script:S(# #print_depth 100;;)}

  $ unix_client exec_toplevel '' '# nested;;'
  {mime_vals:[];parts:[];script:S(# nested;;
    - : int list list list list = [[[[1; 2; 3]]]])}

Test #print_length:

  $ unix_client exec_toplevel '' '# let long_list = [1;2;3;4;5;6;7;8;9;10];;'
  {mime_vals:[];parts:[];script:S(# let long_list = [1;2;3;4;5;6;7;8;9;10];;
    val long_list : int list = [1; 2; 3; 4; 5; 6; 7; 8; 9; 10])}

  $ unix_client exec_toplevel '' '# #print_length 3;;'
  {mime_vals:[];parts:[];script:S(# #print_length 3;;)}

  $ unix_client exec_toplevel '' '# long_list;;'
  {mime_vals:[];parts:[];script:S(# long_list;;
    - : int list = [1; 2; ...])}

  $ unix_client exec_toplevel '' '# #print_length 100;;'
  {mime_vals:[];parts:[];script:S(# #print_length 100;;)}

==============================================
SECTION 4: #install_printer and #remove_printer
==============================================

  $ unix_client exec_toplevel '' '# type color = Red | Green | Blue;;'
  {mime_vals:[];parts:[];script:S(# type color = Red | Green | Blue;;
    type color = Red | Green | Blue)}

  $ unix_client exec_toplevel '' '# let pp_color fmt c = Format.fprintf fmt "<color:%s>" (match c with Red -> "red" | Green -> "green" | Blue -> "blue");;'
  {mime_vals:[];parts:[];script:S(# let pp_color fmt c = Format.fprintf fmt "<color:%s>" (match c with Red -> "red" | Green -> "green" | Blue -> "blue");;
    val pp_color : Format.formatter -> color -> unit = <fun>)}

Test #install_printer:

  $ unix_client exec_toplevel '' '# #install_printer pp_color;;'
  {mime_vals:[];parts:[];script:S(# #install_printer pp_color;;)}

  $ unix_client exec_toplevel '' '# Red;;'
  {mime_vals:[];parts:[];script:S(# Red;;
    - : color = <color:red>)}

  $ unix_client exec_toplevel '' '# [Red; Green; Blue];;'
  {mime_vals:[];parts:[];script:S(# [Red; Green; Blue];;
    - : color list = [<color:red>; <color:green>; <color:blue>])}

Test #remove_printer:

  $ unix_client exec_toplevel '' '# #remove_printer pp_color;;'
  {mime_vals:[];parts:[];script:S(# #remove_printer pp_color;;)}

  $ unix_client exec_toplevel '' '# Red;;'
  {mime_vals:[];parts:[];script:S(# Red;;
    - : color = Red)}

==============================================
SECTION 5: #warnings and #warn_error
==============================================

  $ unix_client exec_toplevel '' '# #warnings "-26";;'
  {mime_vals:[];parts:[];script:S(# #warnings "-26";;)}

Code with unused variable should not warn:

  $ unix_client exec_toplevel '' '# let _ = let unused = 1 in 2;;'
  {mime_vals:[];parts:[];script:S(# let _ = let unused = 1 in 2;;
    - : int = 2)}

Re-enable warning:

  $ unix_client exec_toplevel '' '# #warnings "+26";;'
  {mime_vals:[];parts:[];script:S(# #warnings "+26";;)}

Now should warn:

  $ unix_client exec_toplevel '' '# let _ = let unused2 = 1 in 2;;'
  {mime_vals:[];parts:[];script:S(# let _ = let unused2 = 1 in 2;;
    Line 1, characters 12-19:
    Warning 26 [unused-var]: unused variable unused2.
    - : int = 2)}

Test #warn_error:

  $ unix_client exec_toplevel '' '# #warn_error "+26";;'
  {mime_vals:[];parts:[];script:S(# #warn_error "+26";;)}

  $ unix_client exec_toplevel '' '# let _ = let unused3 = 1 in 2;;'
  {mime_vals:[];parts:[];script:S(# let _ = let unused3 = 1 in 2;;
    Line 1, characters 12-19:
    Error (warning 26 [unused-var]): unused variable unused3.)}

Reset:

  $ unix_client exec_toplevel '' '# #warn_error "-a";;'
  {mime_vals:[];parts:[];script:S(# #warn_error "-a";;)}

==============================================
SECTION 6: #rectypes
==============================================

Without rectypes, recursive type should fail:

  $ unix_client exec_toplevel '' "# type 'a t = 'a t -> int;;"
  {mime_vals:[];parts:[];script:S(# type 'a t = 'a t -> int;;
    Line 1, characters 0-23:
    Error: The type abbreviation t is cyclic:
             'a t = 'a t -> int,
             'a t -> int contains 'a t)}

Enable rectypes:

  $ unix_client exec_toplevel '' '# #rectypes;;'
  {mime_vals:[];parts:[];script:S(# #rectypes;;)}

Now recursive type should work:

  $ unix_client exec_toplevel '' "# type 'a u = 'a u -> int;;"
  {mime_vals:[];parts:[];script:S(# type 'a u = 'a u -> int;;
    type 'a u = 'a u -> int)}

==============================================
SECTION 7: #directory
==============================================

  $ unix_client exec_toplevel '' '# #directory "/tmp";;'
  {mime_vals:[];parts:[];script:S(# #directory "/tmp";;)}

  $ unix_client exec_toplevel '' '# #remove_directory "/tmp";;'
  {mime_vals:[];parts:[];script:S(# #remove_directory "/tmp";;)}

==============================================
SECTION 8: #help
==============================================

  $ unix_client exec_toplevel '' '# #help;;'
  {mime_vals:[];parts:[];script:S(# #help;;
    General
    #help
      Prints a list of all available directives, with corresponding argument type
      if appropriate.
    #quit
      Exit the toplevel.
    
                                  Loading code
    #cd <str>
      Change the current working directory.
    #directory <str>
      Add the given directory to search path for source and compiled files.
    #load <str>
      Load in memory a bytecode object, produced by ocamlc.
    #load_rec <str>
      As #load, but loads dependencies recursively.
    #mod_use <str>
      Usage is identical to #use but #mod_use wraps the contents in a module.
    #remove_directory <str>
      Remove the given directory from the search path.
    #show_dirs
      List directories currently in the search path.
    #use <str>
      Read, compile and execute source phrases from the given file.
    #use_output <str>
      Execute a command and read, compile and execute source phrases from its
      output.
    
                                  Environment queries
    #show <ident>
      Print the signatures of components from any of the categories below.
    #show_class <ident>
      Print the signature of the corresponding class.
    #show_class_type <ident>
      Print the signature of the corresponding class type.
    #show_constructor <ident>
      Print the signature of the corresponding value constructor.
    #show_exception <ident>
      Print the signature of the corresponding exception.
    #show_module <ident>
      Print the signature of the corresponding module.
    #show_module_type <ident>
      Print the signature of the corresponding module type.
    #show_type <ident>
      Print the signature of the corresponding type constructor.
    #show_val <ident>
      Print the signature of the corresponding value.
    
                                  Findlib
    #require <str>
      Load a package (js_top_worker)
    #require <str>
      Load a package (js_top_worker)
    
                                  Pretty-printing
    #install_printer <ident>
      Registers a printer for values of a certain type.
    #print_depth <int>
      Limit the printing of values to a maximal depth of n.
    #print_length <int>
      Limit the number of value nodes printed to at most n.
    #remove_printer <ident>
      Remove the named function from the table of toplevel printers.
    
                                  Tracing
    #trace <ident>
      All calls to the function named function-name will be traced.
    #untrace <ident>
      Stop tracing the given function.
    #untrace_all
      Stop tracing all functions traced so far.
    
                                  Compiler options
    #debug <bool>
      Choose whether to generate debugging events.
    #labels <bool>
      Choose whether to ignore labels in function types.
    #ppx <str>
      After parsing, pipe the abstract syntax tree through the preprocessor
      command.
    #principal <bool>
      Make sure that all types are derived in a principal way.
    #rectypes
      Allow arbitrary recursive types during type-checking.
    #warn_error <str>
      Treat as errors the warnings enabled by the argument.
    #warnings <str>
      Enable or disable warnings according to the argument.
    
                                  Undocumented
    #camlp4o
    #camlp4r
    #list
    #predicates <str>
    #thread)}

==============================================
SECTION 9: #use (File Loading)
==============================================

Create a test file:

  $ cat > /tmp/test_use.ml << 'EOF'
  > let from_file = "loaded via #use"
  > let add x y = x + y
  > EOF

  $ unix_client exec_toplevel '' '# #use "/tmp/test_use.ml";;'
  {mime_vals:[];parts:[];script:S(# #use "/tmp/test_use.ml";;
    val from_file : string = "loaded via #use"
    
    val add : int -> int -> int = <fun>)}

  $ unix_client exec_toplevel '' '# from_file;;'
  {mime_vals:[];parts:[];script:S(# from_file;;
    - : string = "loaded via #use")}

  $ unix_client exec_toplevel '' '# add 1 2;;'
  {mime_vals:[];parts:[];script:S(# add 1 2;;
    - : int = 3)}

==============================================
SECTION 10: #mod_use
==============================================

Create a test file:

  $ cat > /tmp/test_mod.ml << 'EOF'
  > let value = 42
  > type t = A | B
  > EOF

  $ unix_client exec_toplevel '' '# #mod_use "/tmp/test_mod.ml";;'
  {mime_vals:[];parts:[];script:S(# #mod_use "/tmp/test_mod.ml";;
    module Test_mod : sig val value : int type t = A | B end)}

  $ unix_client exec_toplevel '' '# Test_mod.value;;'
  {mime_vals:[];parts:[];script:S(# Test_mod.value;;
    - : int = 42)}

==============================================
SECTION 11: Findlib #require
==============================================

  $ unix_client exec_toplevel '' '# #require "str";;'
  {mime_vals:[];parts:[];script:S(# #require "str";;
    /home/jons-agent/.opam/default/lib/ocaml/str: added to search path)}

  $ unix_client exec_toplevel '' '# Str.regexp "test";;'
  {mime_vals:[];parts:[];script:S(# Str.regexp "test";;
    - : Str.regexp = <abstr>)}

==============================================
SECTION 12: Findlib #list
==============================================

  $ unix_client exec_toplevel '' '# #list;;'
  {mime_vals:[];parts:[];script:S(# #list;;
    0install-solver     (version: 2.18)
    angstrom            (version: 0.16.1)
    angstrom.async      (version: n/a)
    angstrom.lwt-unix   (version: n/a)
    angstrom.unix       (version: n/a)
    asn1-combinators    (version: 0.3.2)
    astring             (version: 0.8.5)
    astring.top         (version: 0.8.5)
    base                (version: v0.17.3)
    base.base_internalhash_types (version: v0.17.3)
    base.md5            (version: v0.17.3)
    base.shadow_stdlib  (version: v0.17.3)
    base64              (version: 3.5.2)
    base64.rfc2045      (version: 3.5.2)
    bigarray-compat     (version: 1.1.0)
    bigstringaf         (version: 0.10.0)
    bos                 (version: 0.2.1)
    bos.setup           (version: 0.2.1)
    bos.top             (version: 0.2.1)
    brr                 (version: 0.0.8)
    brr.ocaml_poke      (version: 0.0.8)
    brr.ocaml_poke_ui   (version: 0.0.8)
    brr.poke            (version: 0.0.8)
    brr.poked           (version: 0.0.8)
    bstr                (version: 0.0.4)
    bytes               (version: [distributed with OCaml 4.02 or above])
    bytesrw             (version: 0.2.0)
    bytesrw.unix        (version: 0.2.0)
    ca-certs            (version: v1.0.1)
    camlp-streams       (version: n/a)
    caqti               (version: v2.2.4)
    caqti-lwt           (version: v2.2.4)
    caqti-lwt.unix      (version: v2.2.4)
    caqti.blocking      (version: v2.2.4)
    caqti.platform      (version: v2.2.4)
    caqti.platform.unix (version: v2.2.4)
    caqti.plugin        (version: v2.2.4)
    caqti.template      (version: v2.2.4)
    checkseum           (version: 0.5.2)
    checkseum.c         (version: 0.5.2)
    checkseum.ocaml     (version: 0.5.2)
    chrome-trace        (version: 3.21.0)
    cmdliner            (version: 1.3.0)
    compiler-libs       (version: 5.4.0)
    compiler-libs.bytecomp (version: 5.4.0)
    compiler-libs.common (version: 5.4.0)
    compiler-libs.native-toplevel (version: 5.4.0)
    compiler-libs.optcomp (version: 5.4.0)
    compiler-libs.toplevel (version: 5.4.0)
    cppo                (version: n/a)
    crunch              (version: 4.0.0)
    csexp               (version: 1.5.2)
    cstruct             (version: 6.2.0)
    decompress          (version: n/a)
    decompress.de       (version: 1.5.3)
    decompress.gz       (version: 1.5.3)
    decompress.lz       (version: 1.5.3)
    decompress.lzo      (version: 1.5.3)
    decompress.zl       (version: 1.5.3)
    digestif            (version: 1.3.0)
    digestif.c          (version: 1.3.0)
    digestif.ocaml      (version: 1.3.0)
    dockerfile          (version: n/a)
    domain-local-await  (version: 1.0.1)
    domain-name         (version: 0.5.0)
    dream               (version: n/a)
    dream-httpaf        (version: n/a)
    dream-pure          (version: n/a)
    dream.certificate   (version: n/a)
    dream.cipher        (version: n/a)
    dream.graphiql      (version: n/a)
    dream.graphql       (version: n/a)
    dream.http          (version: n/a)
    dream.server        (version: n/a)
    dream.sql           (version: n/a)
    dream.unix          (version: n/a)
    dune                (version: n/a)
    dune-action-plugin  (version: 3.21.0)
    dune-build-info     (version: 3.21.0)
    dune-configurator   (version: 3.21.0)
    dune-glob           (version: 3.21.0)
    dune-private-libs   (version: n/a)
    dune-private-libs.dune-section (version: 3.21.0)
    dune-private-libs.meta_parser (version: 3.21.0)
    dune-rpc            (version: 3.21.0)
    dune-rpc-lwt        (version: 3.21.0)
    dune-rpc.private    (version: 3.21.0)
    dune-site           (version: 3.21.0)
    dune-site.dynlink   (version: 3.21.0)
    dune-site.linker    (version: 3.21.0)
    dune-site.plugins   (version: 3.21.0)
    dune-site.private   (version: 3.21.0)
    dune-site.toplevel  (version: 3.21.0)
    dune.configurator   (version: n/a)
    duration            (version: 0.2.1)
    dyn                 (version: 3.21.0)
    dynlink             (version: 5.4.0)
    eio                 (version: n/a)
    eio.core            (version: n/a)
    eio.mock            (version: n/a)
    eio.runtime_events  (version: n/a)
    eio.unix            (version: n/a)
    eio.utils           (version: n/a)
    eio_linux           (version: n/a)
    eio_main            (version: n/a)
    eio_posix           (version: n/a)
    either              (version: 1.0.0)
    eqaf                (version: 0.10)
    eqaf.bigstring      (version: 0.10)
    eqaf.bytes          (version: 0.10)
    faraday             (version: 0.8.2)
    faraday-lwt         (version: 0.8.2)
    faraday-lwt-unix    (version: 0.8.2)
    faraday.async       (version: n/a)
    faraday.lwt         (version: n/a)
    faraday.lwt-unix    (version: n/a)
    fiber               (version: 3.7.0)
    findlib             (version: 1.9.8)
    findlib.dynload     (version: 1.9.8)
    findlib.internal    (version: 1.9.8)
    findlib.top         (version: 1.9.8)
    fix                 (version: n/a)
    fmt                 (version: 0.11.0)
    fmt.cli             (version: 0.11.0)
    fmt.top             (version: 0.11.0)
    fmt.tty             (version: 0.11.0)
    fpath               (version: 0.7.3)
    fpath.top           (version: 0.7.3)
    fs-io               (version: 3.21.0)
    gen                 (version: 1.1)
    gluten              (version: 0.5.2)
    gluten-lwt          (version: 0.5.2)
    gluten-lwt-unix     (version: 0.5.2)
    gmap                (version: 0.3.0)
    graphql             (version: 0.14.0)
    graphql-lwt         (version: 0.14.0)
    graphql_parser      (version: 0.14.0)
    h2                  (version: 0.10.0)
    h2-lwt              (version: 0.10.0)
    h2-lwt-unix         (version: 0.10.0)
    hmap                (version: 0.8.1)
    hpack               (version: 0.12.0-6-g49c0591)
    httpaf              (version: 0.7.1)
    httpun              (version: 0.1.0)
    httpun-lwt          (version: 0.1.0)
    httpun-lwt-unix     (version: 0.1.0)
    httpun-types        (version: 0.1.0)
    httpun-ws           (version: 0.2.0)
    iomux               (version: v0.4)
    ipaddr              (version: 5.6.1)
    ipaddr.top          (version: 5.6.1)
    ipaddr.unix         (version: 5.6.1)
    jane-street-headers (version: v0.17.0)
    js_of_ocaml         (version: 6.2.0)
    js_of_ocaml-compiler (version: 6.2.0)
    js_of_ocaml-compiler.dynlink (version: 6.2.0)
    js_of_ocaml-compiler.findlib-support (version: 6.2.0)
    js_of_ocaml-compiler.runtime (version: 6.2.0)
    js_of_ocaml-compiler.runtime-files (version: 6.2.0)
    js_of_ocaml-lwt     (version: 6.2.0)
    js_of_ocaml-ppx     (version: 6.2.0)
    js_of_ocaml-ppx.as-lib (version: 6.2.0)
    js_of_ocaml-toplevel (version: 6.2.0)
    js_of_ocaml.deriving (version: 6.2.0)
    js_top_worker       (version: 0.0.1)
    js_top_worker-bin   (version: n/a)
    js_top_worker-client (version: 0.0.1)
    js_top_worker-client.msg (version: 0.0.1)
    js_top_worker-client_fut (version: 0.0.1)
    js_top_worker-rpc   (version: 0.0.1)
    js_top_worker-rpc.message (version: 0.0.1)
    js_top_worker-unix  (version: n/a)
    js_top_worker-web   (version: 0.0.1)
    js_top_worker_rpc_def (version: n/a)
    jsonm               (version: 1.0.2)
    jsonrpc             (version: 1.25.0)
    jsont               (version: 0.2.0)
    jsont.brr           (version: 0.2.0)
    jsont.bytesrw       (version: 0.2.0)
    jst-config          (version: v0.17.0)
    kdf                 (version: n/a)
    kdf.hkdf            (version: 1.0.0)
    kdf.pbkdf           (version: 1.0.0)
    kdf.scrypt          (version: 1.0.0)
    ke                  (version: 0.6)
    lambdasoup          (version: n/a)
    logs                (version: 0.10.0)
    logs.browser        (version: 0.10.0)
    logs.cli            (version: 0.10.0)
    logs.fmt            (version: 0.10.0)
    logs.lwt            (version: 0.10.0)
    logs.threaded       (version: 0.10.0)
    logs.top            (version: 0.10.0)
    lru                 (version: 0.3.1)
    lsp                 (version: 1.25.0)
    lwt                 (version: 5.9.2)
    lwt-dllist          (version: 1.1.0)
    lwt.unix            (version: 5.9.2)
    lwt_ppx             (version: 5.9.3)
    lwt_ssl             (version: 1.2.0)
    macaddr             (version: 5.6.1)
    macaddr.top         (version: 5.6.1)
    magic-mime          (version: 1.3.1)
    markup              (version: n/a)
    menhir              (version: n/a)
    menhirCST           (version: 20260122)
    menhirGLR           (version: 20260122)
    menhirLib           (version: 20260122)
    menhirSdk           (version: 20260122)
    merlin-lib          (version: n/a)
    merlin-lib.analysis (version: 5.6.1-504)
    merlin-lib.commands (version: 5.6.1-504)
    merlin-lib.config   (version: 5.6.1-504)
    merlin-lib.dot_protocol (version: 5.6.1-504)
    merlin-lib.extend   (version: 5.6.1-504)
    merlin-lib.index_format (version: 5.6.1-504)
    merlin-lib.kernel   (version: 5.6.1-504)
    merlin-lib.ocaml_compression (version: 5.6.1-504)
    merlin-lib.ocaml_merlin_specific (version: 5.6.1-504)
    merlin-lib.ocaml_parsing (version: 5.6.1-504)
    merlin-lib.ocaml_preprocess (version: 5.6.1-504)
    merlin-lib.ocaml_typing (version: 5.6.1-504)
    merlin-lib.ocaml_utils (version: 5.6.1-504)
    merlin-lib.os_ipc   (version: 5.6.1-504)
    merlin-lib.query_commands (version: 5.6.1-504)
    merlin-lib.query_protocol (version: 5.6.1-504)
    merlin-lib.sherlodoc (version: 5.6.1-504)
    merlin-lib.utils    (version: 5.6.1-504)
    mime_printer        (version: 0.0.1)
    mirage-clock        (version: 4.2.0)
    mirage-crypto       (version: 1.2.0)
    mirage-crypto-ec    (version: 1.2.0)
    mirage-crypto-pk    (version: 1.2.0)
    mirage-crypto-rng   (version: 1.2.0)
    mirage-crypto-rng-lwt (version: 1.2.0)
    mirage-crypto-rng.unix (version: 1.2.0)
    mtime               (version: 2.1.0)
    mtime.clock         (version: 2.1.0)
    mtime.clock.os      (version: 2.1.0)
    mtime.top           (version: 2.1.0)
    multipart_form      (version: 0.7.0)
    multipart_form-lwt  (version: 0.7.0)
    ocaml-compiler-libs (version: n/a)
    ocaml-compiler-libs.bytecomp (version: v0.17.0)
    ocaml-compiler-libs.common (version: v0.17.0)
    ocaml-compiler-libs.optcomp (version: v0.17.0)
    ocaml-compiler-libs.shadow (version: v0.17.0)
    ocaml-compiler-libs.toplevel (version: v0.17.0)
    ocaml-index         (version: n/a)
    ocaml-lsp-server    (version: n/a)
    ocaml-syntax-shims  (version: n/a)
    ocaml-version       (version: n/a)
    ocaml_intrinsics_kernel (version: v0.17.1)
    ocamlbuild          (version: 0.16.1)
    ocamlc-loc          (version: 3.21.0)
    ocamldoc            (version: 5.4.0)
    ocamlformat-lib     (version: 0.28.1)
    ocamlformat-lib.format_ (version: 0.28.1)
    ocamlformat-lib.ocaml_common (version: 0.28.1)
    ocamlformat-lib.ocamlformat_stdlib (version: 0.28.1)
    ocamlformat-lib.odoc_parser (version: 0.28.1)
    ocamlformat-lib.parser_extended (version: 0.28.1)
    ocamlformat-lib.parser_shims (version: 0.28.1)
    ocamlformat-lib.parser_standard (version: 0.28.1)
    ocamlformat-lib.stdlib_shims (version: 0.28.1)
    ocamlformat-rpc-lib (version: 0.28.1)
    ocamlgraph          (version: 2.2.0)
    ocp-indent          (version: n/a)
    ocp-indent.dynlink  (version: 1.9.0)
    ocp-indent.lexer    (version: 1.9.0)
    ocp-indent.lib      (version: 1.9.0)
    ocp-indent.utils    (version: 1.9.0)
    ocplib-endian       (version: n/a)
    ocplib-endian.bigstring (version: n/a)
    ohex                (version: n/a)
    opam-0install       (version: 0.4.2)
    opam-core           (version: n/a)
    opam-core.cmdliner  (version: n/a)
    opam-file-format    (version: 2.2.0)
    opam-format         (version: n/a)
    opam-repository     (version: n/a)
    opam-state          (version: n/a)
    optint              (version: 0.3.0)
    ordering            (version: 3.21.0)
    parsexp             (version: v0.17.0)
    patch               (version: 3.1.0)
    pecu                (version: 0.7)
    pp                  (version: 2.0.0)
    ppx_assert          (version: v0.17.0)
    ppx_assert.runtime-lib (version: v0.17.0)
    ppx_base            (version: v0.17.0)
    ppx_blob            (version: 0.9.0)
    ppx_cold            (version: v0.17.0)
    ppx_compare         (version: v0.17.0)
    ppx_compare.expander (version: v0.17.0)
    ppx_compare.runtime-lib (version: v0.17.0)
    ppx_derivers        (version: n/a)
    ppx_deriving        (version: n/a)
    ppx_deriving.api    (version: 6.1.1)
    ppx_deriving.create (version: 6.1.1)
    ppx_deriving.enum   (version: 6.1.1)
    ppx_deriving.eq     (version: 6.1.1)
    ppx_deriving.fold   (version: 6.1.1)
    ppx_deriving.iter   (version: 6.1.1)
    ppx_deriving.make   (version: 6.1.1)
    ppx_deriving.map    (version: 6.1.1)
    ppx_deriving.ord    (version: 6.1.1)
    ppx_deriving.runtime (version: 6.1.1)
    ppx_deriving.show   (version: 6.1.1)
    ppx_deriving.std    (version: 6.1.1)
    ppx_deriving_rpc    (version: 10.0.0)
    ppx_deriving_yojson (version: 3.10.0)
    ppx_deriving_yojson.runtime (version: 3.10.0)
    ppx_enumerate       (version: v0.17.0)
    ppx_enumerate.runtime-lib (version: v0.17.0)
    ppx_expect          (version: v0.17.3)
    ppx_expect.config   (version: v0.17.3)
    ppx_expect.config_types (version: v0.17.3)
    ppx_expect.evaluator (version: v0.17.3)
    ppx_expect.make_corrected_file (version: v0.17.3)
    ppx_expect.runtime  (version: v0.17.3)
    ppx_globalize       (version: v0.17.2)
    ppx_hash            (version: v0.17.0)
    ppx_hash.expander   (version: v0.17.0)
    ppx_hash.runtime-lib (version: v0.17.0)
    ppx_here            (version: v0.17.0)
    ppx_here.expander   (version: v0.17.0)
    ppx_here.runtime-lib (version: v0.17.0)
    ppx_inline_test     (version: v0.17.1)
    ppx_inline_test.config (version: v0.17.1)
    ppx_inline_test.drop (version: v0.17.1)
    ppx_inline_test.libname (version: v0.17.1)
    ppx_inline_test.runner (version: v0.17.1)
    ppx_inline_test.runner.lib (version: v0.17.1)
    ppx_inline_test.runtime-lib (version: v0.17.1)
    ppx_optcomp         (version: v0.17.1)
    ppx_sexp_conv       (version: v0.17.1)
    ppx_sexp_conv.expander (version: v0.17.1)
    ppx_sexp_conv.runtime-lib (version: v0.17.1)
    ppx_yojson_conv_lib (version: v0.17.0)
    ppxlib              (version: 0.37.0)
    ppxlib.__private__  (version: n/a)
    ppxlib.__private__.ppx_foo_deriver (version: 0.37.0)
    ppxlib.ast          (version: 0.37.0)
    ppxlib.astlib       (version: 0.37.0)
    ppxlib.metaquot     (version: 0.37.0)
    ppxlib.metaquot_lifters (version: 0.37.0)
    ppxlib.print_diff   (version: 0.37.0)
    ppxlib.runner       (version: 0.37.0)
    ppxlib.runner_as_ppx (version: 0.37.0)
    ppxlib.stdppx       (version: 0.37.0)
    ppxlib.traverse     (version: 0.37.0)
    ppxlib.traverse_builtins (version: 0.37.0)
    ppxlib_jane         (version: v0.17.4)
    prettym             (version: 0.0.4)
    psq                 (version: 0.2.1)
    ptime               (version: 1.2.0)
    ptime.clock         (version: 1.2.0)
    ptime.clock.os      (version: 1.2.0)
    ptime.top           (version: 1.2.0)
    re                  (version: n/a)
    re.emacs            (version: n/a)
    re.glob             (version: n/a)
    re.pcre             (version: n/a)
    re.perl             (version: n/a)
    re.posix            (version: n/a)
    re.str              (version: n/a)
    result              (version: 1.5)
    rpclib              (version: 10.0.0)
    rpclib-lwt          (version: 10.0.0)
    rpclib.cmdliner     (version: 10.0.0)
    rpclib.core         (version: 10.0.0)
    rpclib.internals    (version: 10.0.0)
    rpclib.json         (version: 10.0.0)
    rpclib.markdown     (version: 10.0.0)
    rpclib.xml          (version: 10.0.0)
    rresult             (version: 0.7.0)
    rresult.top         (version: 0.7.0)
    runtime_events      (version: 5.4.0)
    sedlex              (version: 3.7)
    sedlex.ppx          (version: 3.7)
    sedlex.utils        (version: 3.7)
    seq                 (version: [distributed with OCaml 4.07 or above])
    sexplib0            (version: v0.17.0)
    sha                 (version: v1.15.4)
    spawn               (version: v0.17.0)
    spdx_licenses       (version: 1.4.0)
    ssl                 (version: 0.7.0)
    stdio               (version: v0.17.0)
    stdlib              (version: 5.4.0)
    stdlib-shims        (version: 0.3.0)
    stdune              (version: 3.21.0)
    str                 (version: 5.4.0)
    stringext           (version: 1.6.0)
    swhid_core          (version: n/a)
    thread-table        (version: 1.0.0)
    threads             (version: 5.4.0)
    threads.posix       (version: [internal])
    time_now            (version: v0.17.0)
    tls                 (version: 2.0.3)
    tls-eio             (version: 2.0.3)
    tls.unix            (version: 2.0.3)
    top-closure         (version: 3.21.0)
    topkg               (version: 1.1.1)
    tyxml               (version: 4.6.0)
    tyxml.functor       (version: 4.6.0)
    uchar               (version: distributed with OCaml 4.03 or above)
    unix                (version: 5.4.0)
    unstrctrd           (version: 0.4)
    unstrctrd.parser    (version: 0.4)
    uri                 (version: 4.4.0)
    uri.services        (version: 4.4.0)
    uri.services_full   (version: 4.4.0)
    uring               (version: v2.7.0)
    uucp                (version: 17.0.0)
    uunf                (version: 17.0.0)
    uunf.string         (version: 17.0.0)
    uuseg               (version: 17.0.0)
    uuseg.string        (version: 17.0.0)
    uutf                (version: 1.0.4)
    x509                (version: 1.0.6)
    xdg                 (version: 3.21.0)
    xdge                (version: v1.0.0)
    xmlm                (version: 1.4.0)
    yojson              (version: 3.0.0)
    zarith              (version: 1.14)
    zarith.top          (version: 1.13)
    zarith_stubs_js     (version: v0.17.0))}

==============================================
SECTION 13: #labels and #principal
==============================================

  $ unix_client exec_toplevel '' '# #labels true;;'
  {mime_vals:[];parts:[];script:S(# #labels true;;)}

  $ unix_client exec_toplevel '' '# #labels false;;'
  {mime_vals:[];parts:[];script:S(# #labels false;;)}

  $ unix_client exec_toplevel '' '# #principal true;;'
  {mime_vals:[];parts:[];script:S(# #principal true;;)}

  $ unix_client exec_toplevel '' '# #principal false;;'
  {mime_vals:[];parts:[];script:S(# #principal false;;)}

==============================================
SECTION 14: Error Cases
==============================================

Unknown directive:

  $ unix_client exec_toplevel '' '# #unknown_directive;;'
  {mime_vals:[];parts:[];script:S(# #unknown_directive;;
    Unknown directive unknown_directive.)}

#show with non-existent identifier:

  $ unix_client exec_toplevel '' '# #show nonexistent_value;;'
  {mime_vals:[];parts:[];script:S(# #show nonexistent_value;;
    Unknown element.)}

#require non-existent package:

  $ unix_client exec_toplevel '' '# #require "nonexistent_package_12345";;'
  {mime_vals:[];parts:[];script:S(# #require "nonexistent_package_12345";;
    No such package: nonexistent_package_12345)}

#use non-existent file:

  $ unix_client exec_toplevel '' '# #use "/nonexistent/file.ml";;'
  {mime_vals:[];parts:[];script:S(# #use "/nonexistent/file.ml";;
    Cannot find file /nonexistent/file.ml.)}

==============================================
SECTION 15: #load (bytecode loading)
==============================================

Note: #load may not work in js_of_ocaml context

  $ unix_client exec_toplevel '' '# #load "str.cma";;'
  {mime_vals:[];parts:[];script:S(# #load "str.cma";;)}

==============================================
SECTION 16: Classes (#show_class)
==============================================

  $ unix_client exec_toplevel '' '# class counter = object val mutable n = 0 method incr = n <- n + 1 method get = n end;;'
  {mime_vals:[];parts:[];script:S(# class counter = object val mutable n = 0 method incr = n <- n + 1 method get = n end;;
    class counter :
      object val mutable n : int method get : int method incr : unit end)}

  $ unix_client exec_toplevel '' '# #show_class counter;;'
  {mime_vals:[];parts:[];script:S(# #show_class counter;;
    class counter :
      object val mutable n : int method get : int method incr : unit end)}

==============================================
Cleanup
==============================================

  $ kill $WORKER_PID 2>/dev/null || true
  $ rm -f "$JS_TOP_WORKER_SOCK"
