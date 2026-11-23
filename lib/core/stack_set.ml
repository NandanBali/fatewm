(** xmonad-style StackSet: the pure model of which windows exist, which
    workspace each belongs to, which workspace each output shows, and where
    focus is.

    Invariants (every function here preserves them):
    - Each workspace id [1..n] appears exactly once, in exactly one of
      [current_output], [visible_outputs] or [hidden_workspaces].
    - Each managed window appears in exactly one workspace stack.
    - [floating] only holds managed windows. A floating window still lives in
      its workspace stack (so it hides/shows with the workspace and takes part
      in focus cycling); the map only says "don't tile it, put it here".
    - [current_output = None] only while no outputs are connected; then every
      workspace is hidden and nothing is lost. *)

open Mlwm_proto.Types
module Wmap = Map.Make (Window_id)

(** {1 The focus zipper} *)

type 'a stack = { focus : 'a; up : 'a list; down : 'a list }
(** A non-empty list with a cursor. [up] holds the windows above the focus
    {e nearest first} (i.e. reversed), [down] the windows below it, so the tiled
    order is [List.rev up @ [focus] @ down] and its head is the master. Moving
    focus is O(1) and "empty workspace" is simply [None]. *)

let integrate s = List.rev_append s.up (s.focus :: s.down)

let of_list = function
  | [] -> None
  | x :: xs -> Some { focus = x; up = []; down = xs }

let member x s = x = s.focus || List.mem x s.up || List.mem x s.down

(* Flipping the list lets every "upward" operation reuse its "downward" twin. *)
let reverse s = { s with up = s.down; down = s.up }

let focus_next s =
  match s.down with
  | d :: ds -> { focus = d; up = s.focus :: s.up; down = ds }
  | [] -> Option.value (of_list (integrate s)) ~default:s (* wrap to top *)

let focus_prev s = reverse (focus_next (reverse s))

(* Swap the focused window with its upper neighbour; at the top it wraps to
   the bottom (xmonad's swapUp). Focus stays on the same window. *)
let swap_up s =
  match s.up with
  | u :: us -> { s with up = us; down = u :: s.down }
  | [] -> { s with up = List.rev s.down; down = [] }

let swap_down s = reverse (swap_up (reverse s))

(* Exchange the focused window with the master. If it already is the master,
   exchange it with the first stack window instead, so the key always does
   something visible. *)
let swap_master s =
  match (List.rev s.up, s.down) with
  | [], [] -> s
  | [], d :: ds -> { s with up = [ d ]; down = ds }
  | master :: rest, down -> { s with up = []; down = rest @ (master :: down) }

(** New windows go just above the focus and take it (xmonad's insertUp). *)
let insert_up x = function
  | None -> { focus = x; up = []; down = [] }
  | Some s -> { s with focus = x; down = s.focus :: s.down }

(** Remove [x]. If it had focus, focus moves to the window below, else above. *)
let delete x s =
  if s.focus = x then
    match (s.down, s.up) with
    | d :: ds, _ -> Some { s with focus = d; down = ds }
    | [], u :: us -> Some { s with focus = u; up = us }
    | [], [] -> None
  else
    let keep = List.filter (fun y -> y <> x) in
    Some { s with up = keep s.up; down = keep s.down }

(** Move the cursor to [x] without reordering anything. *)
let focus_on x s =
  let rec go s = if s.focus = x then s else go (focus_next s) in
  if member x s then go s else s

(** {1 Workspaces and outputs} *)

type workspace = {
  id : int;
  layout : Layout.t;
  stack : Window_id.t stack option;  (** [None] = empty workspace *)
}

type screen = { output : Output.t; workspace : workspace }
(** An active output and the workspace it is currently showing. *)

type t = {
  current_output : screen option;  (** has keyboard focus *)
  visible_outputs : screen list;  (** other active outputs *)
  hidden_workspaces : workspace list;  (** sorted by id *)
  floating : Rect.t Wmap.t;
      (** Floating rects, relative to the origin of the showing output. *)
}

let windows ws = match ws.stack with None -> [] | Some s -> integrate s
let focused_in ws = Option.map (fun s -> s.focus) ws.stack

let empty ~count ~layout =
  {
    current_output = None;
    visible_outputs = [];
    hidden_workspaces =
      List.init count (fun i -> { id = i + 1; layout; stack = None });
    floating = Wmap.empty;
  }

let screens st = Option.to_list st.current_output @ st.visible_outputs

let workspaces st =
  List.map (fun s -> s.workspace) (screens st) @ st.hidden_workspaces

let current_workspace st = Option.map (fun s -> s.workspace) st.current_output

(** The window that should hold keyboard focus, if any. *)
let peek st = Option.bind (current_workspace st) focused_in

let mem w st = List.exists (fun ws -> List.mem w (windows ws)) (workspaces st)

let find_workspace w st =
  List.find_opt (fun ws -> List.mem w (windows ws)) (workspaces st)

let get_workspace id st = List.find_opt (fun ws -> ws.id = id) (workspaces st)
let is_floating w st = Wmap.mem w st.floating

let screen_of_workspace id st =
  List.find_opt (fun s -> s.workspace.id = id) (screens st)

let insert_hidden ws hidden =
  List.sort (fun a b -> Int.compare a.id b.id) (ws :: hidden)

let map_workspaces f st =
  let on_screen s = { s with workspace = f s.workspace } in
  {
    st with
    current_output = Option.map on_screen st.current_output;
    visible_outputs = List.map on_screen st.visible_outputs;
    hidden_workspaces = List.map f st.hidden_workspaces;
  }

let modify_workspace id f st =
  map_workspaces (fun ws -> if ws.id = id then f ws else ws) st

(** Apply [f] to the current workspace. Returns [st] itself (physically) when
    there is no current output, which callers use to detect a no-op. *)
let modify_current f st =
  match st.current_output with
  | None -> st
  | Some s ->
      { st with current_output = Some { s with workspace = f s.workspace } }

let modify_current_stack f =
  modify_current (fun ws -> { ws with stack = Option.map f ws.stack })

(** {1 Window membership} *)

let insert w ~ws st =
  modify_workspace ws
    (fun ws -> { ws with stack = Some (insert_up w ws.stack) })
    st

let remove_from_stacks w st =
  map_workspaces
    (fun ws -> { ws with stack = Option.bind ws.stack (delete w) })
    st

(** Forget [w] entirely: its workspace and its floating rect. *)
let unmanage w st =
  let st = remove_from_stacks w st in
  { st with floating = Wmap.remove w st.floating }

let set_float w rect st = { st with floating = Wmap.add w rect st.floating }
let unset_float w st = { st with floating = Wmap.remove w st.floating }

(** Make the output [id] current; the old current output becomes visible. *)
let set_current_output id st =
  match
    List.partition (fun s -> Output_id.equal s.output.id id) st.visible_outputs
  with
  | [ target ], others ->
      {
        st with
        current_output = Some target;
        visible_outputs = Option.to_list st.current_output @ others;
      }
  | _ -> st

(** Focus [w] inside its workspace. If that workspace is shown on another
    output, that output becomes current, so keyboard focus really lands on [w].
    A window on a hidden workspace only becomes that workspace's focus. *)
let focus_window w st =
  match find_workspace w st with
  | None -> st
  | Some ws -> (
      let st =
        modify_workspace ws.id
          (fun ws -> { ws with stack = Option.map (focus_on w) ws.stack })
          st
      in
      match
        List.find_opt (fun s -> s.workspace.id = ws.id) st.visible_outputs
      with
      | Some s -> set_current_output s.output.id st
      | None -> st)

(** Move [w] to workspace [ws] and make it that workspace's focus. Its floating
    rect (if any) is kept, so it stays floating over there. Returns [st]
    physically unchanged when [w] already lives on [ws] or [ws] does not exist.
*)
let shift w ~ws st =
  match (find_workspace w st, get_workspace ws st) with
  | Some src, Some _ when src.id <> ws -> insert w ~ws (remove_from_stacks w st)
  | _ -> st

(** {1 Switching workspaces (greedyView)} *)

(** Show workspace [id] on the current output:
    - already current: nothing changes (returns [st] physically);
    - visible on another output: the two outputs swap workspaces, and focus
      stays on the current output (xmonad's greedyView);
    - hidden: it replaces the current workspace, which becomes hidden. *)
let view id st =
  match st.current_output with
  | None -> st
  | Some cur when cur.workspace.id = id -> st
  | Some cur -> (
      match List.find_opt (fun s -> s.workspace.id = id) st.visible_outputs with
      | Some other ->
          let swap s =
            if s.workspace.id = id then { s with workspace = cur.workspace }
            else s
          in
          {
            st with
            current_output = Some { cur with workspace = other.workspace };
            visible_outputs = List.map swap st.visible_outputs;
          }
      | None -> (
          match List.partition (fun ws -> ws.id = id) st.hidden_workspaces with
          | [ ws ], rest ->
              {
                st with
                current_output = Some { cur with workspace = ws };
                hidden_workspaces = insert_hidden cur.workspace rest;
              }
          | _ -> st))

(** {1 Outputs} *)

(* Left-to-right, then top-to-bottom: the order Next/Prev cycles through. *)
let spatial_compare (a : Output.t) (b : Output.t) =
  compare
    (a.geometry.x, a.geometry.y, Output_id.to_int a.id)
    (b.geometry.x, b.geometry.y, Output_id.to_int b.id)

let sorted_screens st =
  List.sort (fun a b -> spatial_compare a.output b.output) (screens st)

(** The screen [delta] steps away from the current one in spatial order,
    wrapping around. *)
let neighbour_screen delta st =
  match st.current_output with
  | None -> None
  | Some cur ->
      let ordered = sorted_screens st in
      let n = List.length ordered in
      let rec index i = function
        | [] -> 0
        | s :: rest ->
            if Output_id.equal s.output.id cur.output.id then i
            else index (i + 1) rest
      in
      Some (List.nth ordered ((((index 0 ordered + delta) mod n) + n) mod n))

(** Reconcile with a fresh snapshot of active outputs, never losing a window:
    - outputs that survive (same id) keep their workspace, with new geometry;
    - removed outputs send their workspace to [hidden_workspaces];
    - new outputs take the lowest-numbered hidden workspace (primary first), so
      at startup the primary output shows workspace 1. Outputs beyond the number
      of workspaces are left unused;
    - the current output stays current if it survives, otherwise the primary (or
      leftmost) output becomes current. An empty snapshot hides everything. *)
let reconcile (outputs : Output.t list) st =
  let outputs =
    List.fold_left
      (fun acc (o : Output.t) ->
        if List.exists (fun (p : Output.t) -> Output_id.equal p.id o.id) acc
        then acc
        else acc @ [ o ])
      [] outputs
  in
  let find_new id =
    List.find_opt (fun (o : Output.t) -> Output_id.equal o.id id) outputs
  in
  let kept, dropped =
    List.partition_map
      (fun s ->
        match find_new s.output.id with
        | Some o -> Left { s with output = o }
        | None -> Right s.workspace)
      (screens st)
  in
  let hidden =
    List.fold_left (fun h ws -> insert_hidden ws h) st.hidden_workspaces dropped
  in
  let fresh =
    List.filter
      (fun (o : Output.t) ->
        not (List.exists (fun s -> Output_id.equal s.output.id o.id) kept))
      outputs
    |> List.stable_sort (fun (a : Output.t) b ->
        if a.primary = b.primary then spatial_compare a b
        else if a.primary then -1
        else 1)
  in
  let rec assign hidden acc = function
    | o :: os -> (
        match hidden with
        | ws :: rest -> assign rest ({ output = o; workspace = ws } :: acc) os
        | [] -> (hidden, List.rev acc))
    | [] -> (hidden, List.rev acc)
  in
  let hidden, added = assign hidden [] fresh in
  let all =
    List.sort (fun a b -> spatial_compare a.output b.output) (kept @ added)
  in
  let is_old_current s =
    match st.current_output with
    | Some c -> Output_id.equal c.output.id s.output.id
    | None -> false
  in
  let current =
    match List.find_opt is_old_current all with
    | Some s -> Some s
    | None -> (
        match List.find_opt (fun s -> s.output.primary) all with
        | Some s -> Some s
        | None -> List.nth_opt all 0)
  in
  let others =
    match current with
    | None -> all
    | Some c ->
        List.filter (fun s -> not (Output_id.equal s.output.id c.output.id)) all
  in
  {
    st with
    current_output = current;
    visible_outputs = others;
    hidden_workspaces = hidden;
  }
