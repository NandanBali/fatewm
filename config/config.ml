(** User configuration for [mlwm]. Edit this module and rebuild to apply. *)

open Mlwm_proto.Types
open Mlwm_core.Core

let mod_key = Key.Super

let bind mods sym action = ({ Key.mods; sym }, action)

let workspace_keys =
  List.concat_map
    (fun i ->
      let c = Char.chr (Char.code '0' + i) in
      [
        bind [ mod_key ] (Key.Char c) (Action.View_workspace i);
        bind [ mod_key; Key.Shift ] (Key.Char c) (Action.Move_to_workspace i);
      ])
    [ 1; 2; 3; 4; 5; 6; 7; 8; 9 ]

let default : Config.t =
  {
    workspaces = 9;
    border_width = 2;
    border_focused = 0x5294e2;
    border_unfocused = 0x3b4252;
    default_master_ratio = 0.55;
    keys =
      [
        (* Applications & launchers *)
        bind [ mod_key ] Key.Return (Action.Spawn [ "xterm" ]);
        bind [ mod_key ] (Key.Char 'd')
          (Action.Spawn [ "rofi"; "-show"; "drun" ]);
        bind [ mod_key ] (Key.Char 'p') (Action.Spawn [ "dmenu_run" ]);
        (* Focus & stack manipulation *)
        bind [ mod_key ] (Key.Char 'j') (Action.Focus Action.Next);
        bind [ mod_key ] (Key.Char 'k') (Action.Focus Action.Prev);
        bind [ mod_key; Key.Shift ] Key.Return Action.Swap_master;
        bind [ mod_key; Key.Shift ] (Key.Char 'j') (Action.Swap Action.Next);
        bind [ mod_key; Key.Shift ] (Key.Char 'k') (Action.Swap Action.Prev);
        (* Master ratio & layouts *)
        bind [ mod_key ] (Key.Char 'h') (Action.Resize_master (-0.05));
        bind [ mod_key ] (Key.Char 'l') (Action.Resize_master 0.05);
        bind [ mod_key ] Key.Space Action.Cycle_layout;
        (* Floating & window lifecycle *)
        bind [ mod_key ] (Key.Char 'f') Action.Toggle_float;
        bind [ mod_key; Key.Shift ] (Key.Char 'c') Action.Close_focused;
        (* Multi-monitor *)
        bind [ mod_key ] (Key.Char 'w') (Action.Focus_output Action.Prev);
        bind [ mod_key ] (Key.Char 'e') (Action.Focus_output Action.Next);
        bind [ mod_key; Key.Shift ] (Key.Char 'w')
          (Action.Move_to_output Action.Prev);
        bind [ mod_key; Key.Shift ] (Key.Char 'e')
          (Action.Move_to_output Action.Next);
        (* Session *)
        bind [ mod_key; Key.Shift ] (Key.Char 'r') Action.Restart;
        bind [ mod_key; Key.Shift ] (Key.Char 'q') Action.Quit;
      ]
      @ workspace_keys;
  }
