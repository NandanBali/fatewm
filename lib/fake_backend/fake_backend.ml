(* Pure-OCaml simulated display backend for testing and Backend.S verification. *)

open Mlwm_proto

module Window_map = Map.Make (Types.Window_id)
module Window_set = Set.Make (Types.Window_id)

type trace = {
  init_commands : Command.t list;
  steps : (Event.t * Command.t list) list;
}

type window_state = {
  geometry : Types.Rect.t option;
  border_width : int option;
  visible : bool;
  closed : bool;
}

type world = {
  windows : window_state Window_map.t;
  destroyed : Window_set.t;
  (* Ordered top-to-bottom: head of list is the topmost window. *)
  stacking_order : Types.Window_id.t list;
  focused : Types.Window_id.t option;
  rev_spawned : string list list;
  rev_errors : Command.t list;
  restarted : bool;
  quit : bool;
  outputs : Types.Output.t list;
}

let default_window_state =
  { geometry = None; border_width = None; visible = false; closed = false }

let remove_id id xs =
  List.filter (fun w -> not (Types.Window_id.equal w id)) xs

let ensure_in_stack id stack =
  if List.exists (Types.Window_id.equal id) stack then stack
  else id :: stack

let move_to_top id stack = id :: remove_id id stack

let update_window id f world =
  let windows =
    Window_map.update id (Option.map f) world.windows
  in
  { world with windows }

let is_live world id =
  Window_map.mem id world.windows && not (Window_set.mem id world.destroyed)

let clear_focus_if id focused =
  match focused with
  | Some fid when Types.Window_id.equal fid id -> None
  | _ -> focused

let empty_world ~outputs ~windows =
  let init_win (w : Types.Window_info.t) =
    {
      geometry = Some w.geometry;
      border_width = None;
      visible = true;
      closed = false;
    }
  in
  let win_map =
    List.fold_left
      (fun acc (w : Types.Window_info.t) -> Window_map.add w.id (init_win w) acc)
      Window_map.empty windows
  in
  let stack =
    List.fold_right
      (fun (w : Types.Window_info.t) acc -> ensure_in_stack w.id acc)
      windows []
  in
  {
    windows = win_map;
    destroyed = Window_set.empty;
    stacking_order = stack;
    focused = None;
    rev_spawned = [];
    rev_errors = [];
    restarted = false;
    quit = false;
    outputs;
  }

let apply_command world command =
  let invalid =
    match command with
    | Command.Place_window { id; _ }
    | Command.Show_window id | Command.Hide_window id
    | Command.Raise_window id | Command.Close_window id -> not (is_live world id)
    | Command.Focus_window (Some id) ->
      not (is_live world id) ||
      not (Window_map.find id world.windows).visible
    | Command.Focus_window None | Command.Spawn _ | Command.Restart | Command.Quit ->
      false
  in
  if invalid then { world with rev_errors = command :: world.rev_errors }
  else match command with
  | Command.Place_window { id; geometry; border_width } ->
    let world =
      update_window id
        (fun st ->
          {
            st with
            geometry = Some geometry;
            border_width = Some border_width;
          })
        world
    in
    { world with stacking_order = ensure_in_stack id world.stacking_order }
  | Command.Show_window id ->
    let world = update_window id (fun st -> { st with visible = true }) world in
    { world with stacking_order = ensure_in_stack id world.stacking_order }
  | Command.Hide_window id ->
    let world = update_window id (fun st -> { st with visible = false }) world in
    { world with focused = clear_focus_if id world.focused }
  | Command.Raise_window id ->
    { world with stacking_order = move_to_top id world.stacking_order }
  | Command.Focus_window focused -> { world with focused }
  | Command.Close_window id ->
    update_window id (fun st -> { st with closed = true }) world
  | Command.Spawn argv ->
    { world with rev_spawned = argv :: world.rev_spawned }
  | Command.Restart -> { world with restarted = true }
  | Command.Quit -> { world with quit = true }

let rec apply_commands world = function
  | [] -> world
  | _ when world.quit || world.restarted -> world
  | cmd :: rest -> apply_commands (apply_command world cmd) rest

let apply_event world = function
  | Event.Output_changed outputs -> { world with outputs }
  | Event.Window_requested info ->
    if is_live world info.id then world
    else
      {
        world with
        windows = Window_map.add info.id
            { default_window_state with geometry = Some info.geometry } world.windows;
        destroyed = Window_set.remove info.id world.destroyed;
        stacking_order = ensure_in_stack info.id world.stacking_order;
      }
  | Event.Window_unmapped id ->
    let world =
      if Window_map.mem id world.windows then
        update_window id (fun st -> { st with visible = false }) world
      else world
    in
    { world with focused = clear_focus_if id world.focused }
  | Event.Window_destroyed id ->
    let world =
      if Window_map.mem id world.windows then
        update_window id (fun st -> { st with visible = false }) world
      else world
    in
    {
      world with
      destroyed = Window_set.add id world.destroyed;
      stacking_order = remove_id id world.stacking_order;
      focused = clear_focus_if id world.focused;
    }
  | Event.Window_focus_requested _ | Event.Window_configure_requested _
  | Event.Key_pressed _ -> world

let window_state world id = Window_map.find_opt id world.windows

let window_geometry world id =
  Option.bind (window_state world id) (fun st -> st.geometry)

let window_border_width world id =
  Option.bind (window_state world id) (fun st -> st.border_width)

let is_visible world id =
  match window_state world id with
  | Some st -> st.visible
  | None -> false

let visible_windows world =
  List.filter (is_visible world) world.stacking_order

let stacking_order world = world.stacking_order

let is_above world a b =
  if Types.Window_id.equal a b then false
  else
    let rec loop = function
      | [] -> false
      | x :: rest ->
        if Types.Window_id.equal x a then
          List.exists (Types.Window_id.equal b) rest
        else if Types.Window_id.equal x b then false
        else loop rest
    in
    loop world.stacking_order

let focused world = world.focused

let closed_windows world =
  Window_map.fold
    (fun id st acc -> if st.closed then id :: acc else acc)
    world.windows []
  |> List.rev

let spawned world = List.rev world.rev_spawned
let errors world = List.rev world.rev_errors
let restarted world = world.restarted
let quit world = world.quit
let outputs world = world.outputs

let all_commands trace =
  trace.init_commands @ List.concat_map snd trace.steps

let run_world ~outputs ~windows ~events ~init ~on_event =
  let world0 = empty_world ~outputs ~windows in
  let state0, init_commands = init ~outputs ~windows in
  let world1 = apply_commands world0 init_commands in
  let rec loop st world rev_steps = function
    | [] -> (st, world, { init_commands; steps = List.rev rev_steps })
    | _ when world.quit || world.restarted ->
      (st, world, { init_commands; steps = List.rev rev_steps })
    | ev :: rest ->
      let world_ev = apply_event world ev in
      let st', cmds = on_event st ev in
      let world' = apply_commands world_ev cmds in
      loop st' world' ((ev, cmds) :: rev_steps) rest
  in
  loop state0 world1 [] events

let run_script ~outputs ~windows ~events ~init ~on_event =
  let final_state, _world, trace =
    run_world ~outputs ~windows ~events ~init ~on_event
  in
  (final_state, trace)

module Make (S : sig
  val outputs : Types.Output.t list
  val windows : Types.Window_info.t list
  val events : Event.t list
end) =
struct
  let world_ref = ref None
  let trace_ref = ref None

  let run (_cfg : Backend.config) ~init ~on_event =
    let _st, world, trace =
      run_world ~outputs:S.outputs ~windows:S.windows ~events:S.events ~init
        ~on_event
    in
    world_ref := Some world;
    trace_ref := Some trace

  let last_world () = !world_ref
  let last_trace () = !trace_ref
end
