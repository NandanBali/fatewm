(* The reducer: Event.t -> (StackSet change) -> Command.t list.

   Every handler only edits the pure model ([Stack_set.t]); a single [render]
   function then turns "what should be on screen" into commands by diffing it
   against [placed], the record of what we last told the backend. That keeps
   handlers tiny and makes the emitted commands deterministic and minimal:
   windows are hidden only when they leave visibility, placed only when their
   geometry changes, and shown only when they appear.

   Focus and stacking are diffed the same way, against [focused_sent] and
   [raised]. That matters because mlwm does not own every window: launchers
   like rofi are override-redirect, take input focus and sit on top. A
   background event (some other window closing, a repeated output snapshot)
   must not emit a Focus_window or Raise_window that would steal focus from
   them or cover them. Only user-initiated events — a click or a WM key
   binding — re-assert focus and stacking unconditionally ([~force]). *)

open Mlwm_proto
open Types
module Wmap = Stack_set.Wmap

module Action = struct
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

type t = {
  config : Config.t;
  ss : Stack_set.t;
  placed : Rect.t Wmap.t;
      (** Windows the backend currently shows, with the geometry we last sent.
          Its keys are exactly the visible windows. *)
  focused_sent : Window_id.t option;  (** target of the last Focus_window *)
  raised : Window_id.t list;
      (** Raise sequence the current stacking satisfies (last = topmost). *)
}

let backend_config (cfg : Config.t) : Backend.config =
  {
    key_grabs = List.map (fun (k, _) -> Types.Key.normalize k) cfg.keys;
    border_width = cfg.border_width;
    border_focused = cfg.border_focused;
    border_unfocused = cfg.border_unfocused;
  }

(* Used to centre floating windows when no output exists to centre them on. *)
let fallback_area = { Rect.x = 0; y = 0; w = 1920; h = 1080 }

(* ------------------------------------------------------------------------ *)
(* Rendering                                                                 *)

type placement = {
  win : Window_id.t;
  rect : Rect.t;  (** absolute, border excluded *)
}

(* Where every window of one screen goes: tiled windows in layout order, then
   floating windows at their stored rect translated onto this output. *)
let screen_placements (t : t) (scr : Stack_set.screen) =
  let area = scr.output.geometry in
  let tiled, floats =
    List.partition
      (fun w -> not (Stack_set.is_floating w t.ss))
      (Stack_set.windows scr.workspace)
  in
  let rects =
    Layout.arrange scr.workspace.layout ~border_width:t.config.border_width area
      (List.length tiled)
  in
  let float_rect w =
    Layout.fit ~border_width:t.config.border_width area
      (Wmap.find w t.ss.floating)
  in
  List.map2 (fun win rect -> { win; rect }) tiled rects
  @ List.map (fun win -> { win; rect = float_rect win }) floats

(* Stacking for one screen: in Monocle the focused tiled window goes on top of
   its siblings; floating windows always go above the tiled ones, with the
   focused floating window raised last so it ends up topmost. *)
let screen_raises (t : t) (scr : Stack_set.screen) =
  let ws = scr.workspace in
  let focus = Stack_set.focused_in ws in
  let is_float w = Stack_set.is_floating w t.ss in
  let monocle =
    match (ws.layout, focus) with
    | Layout.Monocle, Some f when not (is_float f) -> [ f ]
    | _ -> []
  in
  let floats = List.filter is_float (Stack_set.windows ws) in
  let unfocused, focused = List.partition (fun w -> Some w <> focus) floats in
  monocle @ unfocused @ focused

(* [xs] is [ys] with some elements dropped and the order kept. *)
let rec is_subsequence xs ys =
  match (xs, ys) with
  | [], _ -> true
  | _, [] -> false
  | x :: xs', y :: ys' ->
      if Window_id.equal x y then is_subsequence xs' ys'
      else is_subsequence xs ys'

(* Turn the model into commands, diffing against what we last sent:
   1. Hide windows that were visible and are not any more (but are still
      managed: a destroyed/unmapped window is already gone from the screen);
   2. Place (+ Show, if newly visible) every visible window;
   3. Raise floating windows and the Monocle focus — only if the stacking we
      want is not already in place (see below) or [force];
   4. Focus the current output's focused window (or nothing) — only if that
      differs from what we last focused, or [force].

   Stacking is already in place when nothing new appeared and the wanted raise
   sequence is the old one with some windows dropped: X keeps the relative
   order of what we raised before. A newly shown window may come up on top
   (new clients are created topmost), so any Show triggers the raises.

   For focus, "differs from what we last sent" also covers the focused window
   being hidden, unmapped or destroyed in this step: the current output's focus
   is always visible and managed, so it cannot still be that window. *)
let render ?(force = false) (t : t) =
  let screens = Stack_set.sorted_screens t.ss in
  let placements = List.concat_map (screen_placements t) screens in
  let placed =
    List.fold_left (fun m p -> Wmap.add p.win p.rect m) Wmap.empty placements
  in
  let hides =
    Wmap.fold
      (fun w _ acc ->
        if Wmap.mem w placed || not (Stack_set.mem w t.ss) then acc
        else Command.Hide_window w :: acc)
      t.placed []
    |> List.rev
  in
  let place p =
    Command.Place_window
      { id = p.win; geometry = p.rect; border_width = t.config.border_width }
  in
  let moves =
    List.concat_map
      (fun p ->
        match Wmap.find_opt p.win t.placed with
        | None -> [ place p; Command.Show_window p.win ]
        | Some r when Rect.equal r p.rect -> []
        | Some _ -> [ place p ])
      placements
  in
  let raised = List.concat_map (screen_raises t) screens in
  let shown = List.exists (fun p -> not (Wmap.mem p.win t.placed)) placements in
  let raises =
    if force || shown || not (is_subsequence raised t.raised) then
      List.map (fun w -> Command.Raise_window w) raised
    else []
  in
  let want = Stack_set.peek t.ss in
  let focus =
    if force || not (Option.equal Window_id.equal want t.focused_sent) then
      [ Command.Focus_window want ]
    else []
  in
  ( { t with placed; raised; focused_sent = want },
    hides @ moves @ raises @ focus )

(* Commit a new model. Stack_set operations return their input physically
   unchanged when they are a no-op (e.g. viewing the workspace already shown),
   in which case we emit nothing at all. *)
let update ?force t ss =
  if ss == t.ss then (t, []) else render ?force { t with ss }

(* ------------------------------------------------------------------------ *)
(* Event handlers                                                            *)

(* The output area a window on workspace [ws_id] should be centred on: the
   output showing it, else the current output. *)
let area_for t ws_id =
  match (Stack_set.screen_of_workspace ws_id t.ss, t.ss.current_output) with
  | Some s, _ | None, Some s -> s.output.geometry
  | None, None -> fallback_area

(* Start managing a window. Transients follow their parent's workspace;
   everything else lands on the current workspace (workspace 1 if no output
   exists yet). [?ws] forces the workspace, used when adopting at startup. *)
let manage ?ws t (info : Window_info.t) =
  let ss = t.ss in
  let parent_ws =
    Option.bind info.transient_for (fun p -> Stack_set.find_workspace p ss)
    |> Option.map (fun (w : Stack_set.workspace) -> w.id)
  in
  let ws_id =
    match (ws, parent_ws, Stack_set.current_workspace ss) with
    | Some id, _, _ | None, Some id, _ -> id
    | None, None, Some cur -> cur.id
    | None, None, None -> 1
  in
  let ss = Stack_set.insert info.id ~ws:ws_id ss in
  let ss =
    if info.floating_hint then
      let rect =
        Layout.center ~border_width:t.config.border_width (area_for t ws_id)
          ~w:info.geometry.w ~h:info.geometry.h
      in
      Stack_set.set_float info.id rect ss
    else ss
  in
  Stack_set.focus_window info.id ss

let toggle_float t w =
  if Stack_set.is_floating w t.ss then Stack_set.unset_float w t.ss
  else
    (* Entering float: a centred window at 60% of the output's size. *)
    let area =
      area_for t
        (Option.fold ~none:1
           ~some:(fun (ws : Stack_set.workspace) -> ws.id)
           (Stack_set.find_workspace w t.ss))
    in
    let rect =
      Layout.center ~border_width:t.config.border_width area
        ~w:(area.w * 3 / 5)
        ~h:(area.h * 3 / 5)
    in
    Stack_set.set_float w rect t.ss

(* A client asked to move/resize itself. Only floating windows may: a tiled
   window's geometry belongs to the layout, and the backend's synthetic
   ConfigureNotify tells the client "no". [g] is root-relative, so it is stored
   relative to the output showing the window (render then clamps it with
   {!Layout.fit}). On a hidden workspace we cannot tell which output the
   client meant its x/y for, so only the size is taken. Returns [t.ss]
   physically unchanged when nothing changes. *)
let configure t w (g : Rect.t) =
  let ss = t.ss in
  match (Wmap.find_opt w ss.floating, Stack_set.find_workspace w ss) with
  | Some old, Some ws ->
      let w' = max 1 g.w and h' = max 1 g.h in
      let rect =
        match Stack_set.screen_of_workspace ws.id ss with
        | Some s ->
            let o = s.output.geometry in
            { Rect.x = g.x - o.x; y = g.y - o.y; w = w'; h = h' }
        | None -> { old with w = w'; h = h' }
      in
      if Rect.equal rect old then ss else Stack_set.set_float w rect ss
  | _ -> ss

let delta = function Action.Next -> 1 | Action.Prev -> -1

(* A WM key binding only fires when no other client holds a keyboard grab, so
   the user is talking to mlwm itself: every action that changes the model
   re-asserts focus and stacking ([~force:true]), which also recovers focus
   lost to an unmanaged window. Actions that change nothing still emit []. *)
let act t (action : Action.t) =
  let ss = t.ss in
  let update = update ~force:true in
  (* Most actions are about the focused window; with none they do nothing. *)
  let with_focused f =
    match Stack_set.peek ss with Some w -> update t (f w) | None -> (t, [])
  in
  let stack f = update t (Stack_set.modify_current_stack f ss) in
  (* Reordering only means something for tiled windows: swapping a floating
     window would silently shuffle the stack with no visible effect. *)
  let swap f =
    match Stack_set.peek ss with
    | Some w when not (Stack_set.is_floating w ss) -> stack f
    | _ -> (t, [])
  in
  let layout f =
    update t
      (Stack_set.modify_current (fun ws -> { ws with layout = f ws.layout }) ss)
  in
  match action with
  | Focus Next -> stack Stack_set.focus_next
  | Focus Prev -> stack Stack_set.focus_prev
  | Swap_master -> swap Stack_set.swap_master
  | Swap Next -> swap Stack_set.swap_down
  | Swap Prev -> swap Stack_set.swap_up
  | Resize_master d -> layout (Layout.resize d)
  | Cycle_layout ->
      layout (Layout.cycle ~default_ratio:t.config.default_master_ratio)
  | Toggle_float -> with_focused (toggle_float t)
  | Close_focused ->
      ( t,
        Stack_set.peek ss
        |> Option.map (fun w -> Command.Close_window w)
        |> Option.to_list )
  | View_workspace n -> update t (Stack_set.view n ss)
  | Move_to_workspace n -> with_focused (fun w -> Stack_set.shift w ~ws:n ss)
  | Focus_output dir -> (
      match Stack_set.neighbour_screen (delta dir) ss with
      | Some s -> update t (Stack_set.set_current_output s.output.id ss)
      | None -> (t, []))
  | Move_to_output dir -> (
      match Stack_set.neighbour_screen (delta dir) ss with
      | Some s ->
          with_focused (fun w -> Stack_set.shift w ~ws:s.workspace.id ss)
      | None -> (t, []))
  | Spawn argv -> (t, [ Command.Spawn argv ])
  | Restart -> (t, [ Command.Restart ])
  | Quit -> (t, [ Command.Quit ])

let lookup_key (cfg : Config.t) binding =
  let binding = Key.normalize binding in
  List.find_map
    (fun (k, a) -> if Key.equal (Key.normalize k) binding then Some a else None)
    cfg.keys

let step t (event : Event.t) =
  match event with
  | Output_changed outputs -> update t (Stack_set.reconcile outputs t.ss)
  | Window_requested info ->
      if Stack_set.mem info.id t.ss then (t, [])
      else render { t with ss = manage t info }
  | Window_unmapped w | Window_destroyed w ->
      if Stack_set.mem w t.ss then
        render { t with ss = Stack_set.unmanage w t.ss }
      else (t, [])
  | Window_focus_requested w ->
      (* A click is explicit: focus [w] even if we believe it already has
         focus, since an unmanaged client may have taken it meanwhile. *)
      if Stack_set.mem w t.ss then
        render ~force:true { t with ss = Stack_set.focus_window w t.ss }
      else (t, [])
  | Window_configure_requested { id; geometry } ->
      (* Background event: at most a Place for the window itself, never a
         forced Focus or Raise. *)
      update t (configure t id geometry)
  | Key_pressed binding -> (
      match lookup_key t.config binding with
      | Some a -> act t a
      | None -> (t, []))

(* Adopt the outputs and the windows that already existed at startup (or
   survived a Restart). All adopted windows go to workspace 1, keeping their
   original order (the first one ends up as master and focused). *)
let init (config : Config.t) ~outputs ~windows =
  let layout =
    Layout.Tall
      { master_ratio = Layout.clamp_ratio config.default_master_ratio }
  in
  let ss =
    Stack_set.empty ~count:(max 1 config.workspaces) ~layout
    |> Stack_set.reconcile outputs
  in
  let t =
    { config; ss; placed = Wmap.empty; focused_sent = None; raised = [] }
  in
  let t =
    List.fold_left
      (fun t (info : Window_info.t) ->
        if Stack_set.mem info.id t.ss then t
        else { t with ss = manage ~ws:1 t info })
      t (List.rev windows)
  in
  let t, cmds = render ~force:true t in
  (* Adopted windows are already mapped. Any that we are not showing (only
     possible when there is no output yet) must be hidden explicitly. *)
  let hides =
    List.map (fun (i : Window_info.t) -> i.id) windows
    |> List.sort_uniq Window_id.compare
    |> List.filter (fun w -> not (Wmap.mem w t.placed))
    |> List.map (fun w -> Command.Hide_window w)
  in
  (t, hides @ cmds)

(* ------------------------------------------------------------------------ *)
(* Read-only inspection                                                      *)

let focused t = Stack_set.peek t.ss

let current_workspace t =
  Option.map
    (fun (ws : Stack_set.workspace) -> ws.id)
    (Stack_set.current_workspace t.ss)

let current_output t =
  Option.map (fun (s : Stack_set.screen) -> s.output.id) t.ss.current_output

let visible_workspaces t =
  List.map
    (fun (s : Stack_set.screen) -> (s.output.id, s.workspace.id))
    (Stack_set.sorted_screens t.ss)

let hidden_workspaces t =
  List.map (fun (ws : Stack_set.workspace) -> ws.id) t.ss.hidden_workspaces

let workspace_windows t id =
  Option.fold ~none:[] ~some:Stack_set.windows (Stack_set.get_workspace id t.ss)

let workspace_of t w =
  Option.map
    (fun (ws : Stack_set.workspace) -> ws.id)
    (Stack_set.find_workspace w t.ss)

let workspace_layout t id =
  Option.map
    (fun (ws : Stack_set.workspace) -> ws.layout)
    (Stack_set.get_workspace id t.ss)

let is_floating t w = Stack_set.is_floating w t.ss
let is_visible t w = Wmap.mem w t.placed
let geometry t w = Wmap.find_opt w t.placed
