(** Multiple isolated execution environments.

    This module provides isolated execution environments for the OCaml toplevel.
    Each environment maintains both:
    - The typing environment (Env.t) which tracks type bindings
    - Runtime values (via Toploop.getvalue/setvalue) which store actual values

    When switching between environments, both are saved and restored to ensure
    complete isolation of definitions. *)

module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

(* Debug logging - uses the Logs module which is configured in the worker *)
let log_debug msg = Logs.debug (fun m -> m "%s" msg)

type id = string

(** Runtime values are stored as a map from binding name to Obj.t.
    We use Obj.t because Toploop.getvalue/setvalue work with Obj.t. *)
type runtime_values = Obj.t StringMap.t

type t = {
  id : id;
  mutable toplevel_env : Env.t option;
  mutable runtime_values : runtime_values;
  mutable is_setup : bool;
  failed_cells : StringSet.t ref;
}

let default_id = "default"

(* Global table of environments *)
let environments : (id, t) Hashtbl.t = Hashtbl.create 16

let create id =
  let env = {
    id;
    toplevel_env = None;
    runtime_values = StringMap.empty;
    is_setup = false;
    failed_cells = ref StringSet.empty;
  } in
  Hashtbl.replace environments id env;
  env

let get id = Hashtbl.find_opt environments id

let get_or_create id =
  match get id with
  | Some env -> env
  | None -> create id

let destroy id = Hashtbl.remove environments id

let list () = Hashtbl.fold (fun id _ acc -> id :: acc) environments []

let id env = env.id

(** Get the toplevel name for a binding identifier.
    This is used to look up runtime values via Toploop.getvalue. *)
let toplevel_name ident = Translmod.toplevel_name ident

(** Restore runtime values from the stored map.
    This sets the values in the bytecode global table. *)
let restore_runtime_values env_id values =
  let count = StringMap.cardinal values in
  if count > 0 then
    log_debug (Printf.sprintf "[ENV] Restoring %d runtime values for env %s" count env_id);
  StringMap.iter (fun name value ->
    try
      log_debug (Printf.sprintf "[ENV]   setvalue %s" name);
      Toploop.setvalue name value
    with e ->
      log_debug (Printf.sprintf "[ENV]   setvalue %s failed: %s" name (Printexc.to_string e))
  ) values

(** Check if an identifier is a value binding in the given environment.
    Returns true for let-bindings, false for exceptions, modules, types, etc. *)
let is_value_binding typing_env ident =
  try
    let path = Path.Pident ident in
    let _ = Env.find_value path typing_env in
    true
  with Not_found -> false

(** Capture runtime values for the given identifiers.
    Only captures value bindings (not exceptions, modules, etc.).
    Returns an updated map with the new values. *)
let capture_runtime_values typing_env env_id base_map idents =
  (* Filter to only value bindings to avoid "Fatal error" from Toploop.getvalue *)
  let value_idents = List.filter (is_value_binding typing_env) idents in
  if value_idents <> [] then
    log_debug (Printf.sprintf "[ENV] Capturing %d value bindings for env %s (filtered from %d total)"
      (List.length value_idents) env_id (List.length idents));
  List.fold_left (fun map ident ->
    let name = toplevel_name ident in
    try
      let value = Toploop.getvalue name in
      log_debug (Printf.sprintf "[ENV]   captured %s" name);
      StringMap.add name value map
    with e ->
      log_debug (Printf.sprintf "[ENV]   could not capture %s: %s" name (Printexc.to_string e));
      map
  ) base_map value_idents

let with_env env f =
  log_debug (Printf.sprintf "[ENV] with_env called for %s (has_saved_env=%b, runtime_values_count=%d)"
    env.id (Option.is_some env.toplevel_env) (StringMap.cardinal env.runtime_values));

  (* Save current toplevel environment *)
  let saved_typing_env = !Toploop.toplevel_env in
  let saved_typing_env_before =
    match env.toplevel_env with
    | Some e -> e
    | None -> saved_typing_env
  in

  (* Restore this environment's typing environment if we have one *)
  (match env.toplevel_env with
   | Some e -> Toploop.toplevel_env := e
   | None -> ());

  (* Restore this environment's runtime values *)
  restore_runtime_values env.id env.runtime_values;

  (* Run the function *)
  let result =
    try f ()
    with exn ->
      (* Capture new bindings before re-raising *)
      let current_typing_env = !Toploop.toplevel_env in
      let new_idents = Env.diff saved_typing_env_before current_typing_env in
      let updated_values = capture_runtime_values current_typing_env env.id env.runtime_values new_idents in
      env.runtime_values <- updated_values;
      env.toplevel_env <- Some current_typing_env;
      Toploop.toplevel_env := saved_typing_env;
      raise exn
  in

  (* Capture new bindings that were added during execution *)
  let current_typing_env = !Toploop.toplevel_env in
  let new_idents = Env.diff saved_typing_env_before current_typing_env in
  log_debug (Printf.sprintf "[ENV] Env.diff found %d new idents for %s" (List.length new_idents) env.id);
  let updated_values = capture_runtime_values current_typing_env env.id env.runtime_values new_idents in

  (* Save the updated environment state *)
  env.runtime_values <- updated_values;
  env.toplevel_env <- Some !Toploop.toplevel_env;

  (* Restore the previous typing environment *)
  Toploop.toplevel_env := saved_typing_env;

  result

let is_setup env = env.is_setup

let mark_setup env = env.is_setup <- true

let get_failed_cells env = !(env.failed_cells)

let add_failed_cell env cell_id =
  env.failed_cells := StringSet.add cell_id !(env.failed_cells)

let remove_failed_cell env cell_id =
  env.failed_cells := StringSet.remove cell_id !(env.failed_cells)

let is_cell_failed env cell_id =
  StringSet.mem cell_id !(env.failed_cells)
