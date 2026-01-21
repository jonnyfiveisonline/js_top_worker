(** Multiple isolated execution environments. *)

module StringSet = Set.Make (String)

type id = string

type t = {
  id : id;
  mutable toplevel_env : Env.t option;
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

let with_env env f =
  (* Save current toplevel environment *)
  let saved = !Toploop.toplevel_env in
  (* Restore this environment's state if we have one *)
  (match env.toplevel_env with
   | Some e -> Toploop.toplevel_env := e
   | None -> ());
  (* Run the function *)
  let result =
    try f ()
    with exn ->
      (* Save the environment state before re-raising *)
      env.toplevel_env <- Some !Toploop.toplevel_env;
      Toploop.toplevel_env := saved;
      raise exn
  in
  (* Save the updated environment state *)
  env.toplevel_env <- Some !Toploop.toplevel_env;
  (* Restore the previous environment *)
  Toploop.toplevel_env := saved;
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
