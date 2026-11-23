(** Pure-OCaml window manager rules core.
    Depends ONLY on [Mlwm_proto] — zero X11, Wayland, or C dependencies. *)

open Mlwm_proto

module Action : sig
  type dir =
    | Next
    | Prev

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

(** Extract backend startup parameters (key grabs + border styling) from config. *)
val backend_config : Config.t -> Backend.config

(** Build initial WM state from discovered outputs and adopted startup windows. *)
val init :
  Config.t ->
  outputs:Types.Output.t list ->
  windows:Types.Window_info.t list ->
  t * Command.t list

(** Pure state transition: consume one backend event, return next state and commands. *)
val step : t -> Event.t -> t * Command.t list
