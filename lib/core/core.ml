open Mlwm_proto

module Action = struct
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

module Config = struct
  type t = {
    workspaces : int;
    border_width : int;
    border_focused : Types.Color.t;
    border_unfocused : Types.Color.t;
    default_master_ratio : float;
    keys : (Types.Key.binding * Action.t) list;
  }
end

type t = { config : Config.t }

let backend_config (cfg : Config.t) : Backend.config =
  {
    key_grabs = List.map (fun (k, _) -> Types.Key.normalize k) cfg.keys;
    border_width = cfg.border_width;
    border_focused = cfg.border_focused;
    border_unfocused = cfg.border_unfocused;
  }

(* M0 placeholder — implemented in M1/M2 by the Core Rules agent. *)
let init config ~outputs:_ ~windows:_ = ({ config }, [])

let step state _event =
  ignore state.config;
  (state, [])
