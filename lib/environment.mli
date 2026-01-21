(** Multiple isolated execution environments.

    This module provides support for running multiple isolated OCaml
    evaluation contexts within a single worker. Each environment has
    its own type environment, allowing independent code execution
    without interference.

    Libraries are shared across all environments to save memory - once
    a library is loaded, it's available to all environments. *)

(** {1 Types} *)

type t
(** An isolated execution environment. *)

type id = string
(** Environment identifier. *)

(** {1 Environment Management} *)

val create : id -> t
(** [create id] creates a new environment with the given identifier.
    The environment starts uninitialized; call [setup] after creation. *)

val get : id -> t option
(** [get id] returns the environment with the given identifier, if it exists. *)

val get_or_create : id -> t
(** [get_or_create id] returns the existing environment or creates a new one. *)

val destroy : id -> unit
(** [destroy id] removes the environment with the given identifier. *)

val list : unit -> id list
(** [list ()] returns all environment identifiers. *)

val default_id : id
(** The default environment identifier used when none is specified. *)

val id : t -> id
(** [id env] returns the identifier of the environment. *)

(** {1 Environment Switching} *)

val with_env : t -> (unit -> 'a) -> 'a
(** [with_env env f] runs [f ()] in the context of environment [env].
    The toplevel environment is saved before and restored after,
    allowing isolated execution. *)

(** {1 Environment State} *)

val is_setup : t -> bool
(** [is_setup env] returns whether [setup] has been called for this environment. *)

val mark_setup : t -> unit
(** [mark_setup env] marks the environment as having completed setup. *)

(** {1 Failed Cells Tracking} *)

module StringSet : Set.S with type elt = string

val get_failed_cells : t -> StringSet.t
(** [get_failed_cells env] returns the set of cell IDs that failed to compile. *)

val add_failed_cell : t -> string -> unit
(** [add_failed_cell env cell_id] marks a cell as failed. *)

val remove_failed_cell : t -> string -> unit
(** [remove_failed_cell env cell_id] marks a cell as no longer failed. *)

val is_cell_failed : t -> string -> bool
(** [is_cell_failed env cell_id] checks if a cell is marked as failed. *)
