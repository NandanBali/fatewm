(** Pure-OCaml window manager rules core. Depends ONLY on [Mlwm_proto] — zero
    X11, Wayland, or C dependencies. *)

open Mlwm_proto

module Action : sig
  type dir = Next | Prev

  type t =
    | Focus of dir
    | Swap_master
    | Swap of dir
    | Resize_master of float
    | Cycle_layout
    | Toggle_float
    | Close_focused
    | View_workspace of int
    | Move_to_workspace of int
    | Focus_output of dir
    | Move_to_output of dir
    | Spawn of string list
    | Restart
    | Quit
end

module Config : sig
  type t = {
    workspaces : int;
    border_width : int;
    border_focused : Types.Color.t;
    border_unfocused : Types.Color.t;
    default_master_ratio : float;
    keys : (Types.Key.binding * Action.t) list;
  }
end

type t

val backend_config : Config.t -> Backend.config
(** Extract backend startup parameters (key grabs + border styling) from config.
*)

val init :
  Config.t ->
  outputs:Types.Output.t list ->
  windows:Types.Window_info.t list ->
  t * Command.t list
(** Build initial WM state from discovered outputs and adopted startup windows.
*)

val step : t -> Event.t -> t * Command.t list
(** Pure state transition: consume one backend event, return next state and
    commands. *)

(** {1 Read-only inspection}
    Handy for tests and debugging; none of these affect behaviour. *)

val focused : t -> Types.Window_id.t option
(** Window that holds (or should hold) keyboard focus. *)

val current_workspace : t -> int option
(** Workspace shown on the current output ([None] when no output exists). *)

val current_output : t -> Types.Output_id.t option

val visible_workspaces : t -> (Types.Output_id.t * int) list
(** [(output, workspace)] for every active output, left-to-right. *)

val hidden_workspaces : t -> int list
(** Ids of workspaces not shown on any output, ascending. *)

val workspace_windows : t -> int -> Types.Window_id.t list
(** Windows of a workspace in stack order (head = master), floating ones
    included. Empty for unknown ids. *)

val workspace_of : t -> Types.Window_id.t -> int option
val workspace_layout : t -> int -> Layout.t option
val is_floating : t -> Types.Window_id.t -> bool

val is_visible : t -> Types.Window_id.t -> bool
(** Whether the backend was last told to show this window. *)

val geometry : t -> Types.Window_id.t -> Types.Rect.t option
(** Geometry last sent for a visible window. *)
