open Mlwm_proto
open Types
module X = Mlwm_x11_c.X11_c

(* The core knows workspaces; these tables know only protocol obligations. *)
type placement = { geometry : Rect.t; border_width : int }

let run (config : Backend.config) ~init ~on_event =
  let display = X.open_display () in
  let managed = Hashtbl.create 32 in
  let placed_geom = Hashtbl.create 32 in
  let ignore_unmap = Hashtbl.create 32 in
  let focused = ref None in
  let closed = ref false in
  let release_all () =
    if not !closed then (
      (* One cleanup path for Quit, Restart, exceptions, and process exit.
         Remapping hidden clients makes restart adoption and WM exit usable. *)
      closed := true;
      Fun.protect
        ~finally:(fun () -> X.close display)
        (fun () ->
          Hashtbl.iter (fun id () -> X.release display id) managed;
          Hashtbl.clear ignore_unmap;
          X.sync display))
  in
  at_exit release_all;
  let remember (window : Window_info.t) =
    let id = Window_id.to_int window.id in
    if not (Hashtbl.mem managed id) then (
      X.manage display id;
      Hashtbl.add managed id ();
      Hashtbl.replace placed_geom id
        { geometry = window.geometry; border_width = config.border_width })
  in
  let forget ~destroyed id =
    (* The server already drops grabs/save-set membership for destroyed windows. *)
    if not destroyed then X.unmanage display id;
    Hashtbl.remove managed id;
    Hashtbl.remove placed_geom id;
    Hashtbl.remove ignore_unmap id;
    if !focused = Some id then focused := None
  in
  let decorate id is_focused =
    if Hashtbl.mem managed id then
      X.decorate display id
        (if is_focused then config.border_focused else config.border_unfocused)
        (not is_focused)
  in
  let set_focus target =
    let target = Option.map Window_id.to_int target in
    let target = match target with
      | Some id when Hashtbl.mem managed id -> Some id
      | _ -> None
    in
    let previous = !focused in
    focused := target;
    Option.iter (fun id -> decorate id false) previous;
    Option.iter (fun id -> decorate id true) target;
    X.focus display target
  in
  let rec execute = function
    | [] -> true
    | Command.Quit :: _ -> false
    | Command.Restart :: _ ->
        X.flush display;
        release_all ();
        Unix.execv Sys.executable_name Sys.argv
    | command :: rest ->
        (match command with
        | Command.Place_window { id; geometry; border_width } ->
            let id = Window_id.to_int id in
            if Hashtbl.mem managed id then (
              let geometry = { geometry with Rect.w = max 1 geometry.w;
                                              h = max 1 geometry.h } in
              let border_width = max 0 border_width in
              Hashtbl.replace placed_geom id { geometry; border_width };
              let color = if !focused = Some id then config.border_focused
                          else config.border_unfocused in
              X.place display id geometry border_width color;
              decorate id (!focused = Some id))
        | Command.Show_window id ->
            let id = Window_id.to_int id in
            if Hashtbl.mem managed id then X.show display id
        | Command.Hide_window id ->
            let id = Window_id.to_int id in
            if Hashtbl.mem managed id then (
              let count = Option.value ~default:0 (Hashtbl.find_opt ignore_unmap id) in
              Hashtbl.replace ignore_unmap id (count + 1);
              (* Already hidden windows generate no new notification. *)
              if not (X.hide display id) then
                if count = 0 then Hashtbl.remove ignore_unmap id
                else Hashtbl.replace ignore_unmap id count)
        | Command.Raise_window id ->
            let id = Window_id.to_int id in
            if Hashtbl.mem managed id then X.raise_window display id
        | Command.Focus_window target -> set_focus target
        | Command.Close_window id ->
            let id = Window_id.to_int id in
            if Hashtbl.mem managed id then X.close_window display id
        | Command.Spawn argv -> X.spawn (Array.of_list argv)
        | Command.Quit | Command.Restart -> assert false);
        execute rest
  in
  let outputs = ref [] in
  let query_outputs () =
    X.query_outputs display
    |> List.sort (fun (a : Output.t) b -> Output_id.compare a.id b.id)
  in
  let decode = function
    | X.Ignored -> None
    | X.Mapping_changed -> X.grab_keys display config.key_grabs; None
    | X.Outputs_changed ->
        let current = query_outputs () in
        if List.equal Output.equal !outputs current then None
        else (outputs := current; Some (Event.Output_changed current))
    | X.Map_request window ->
        remember window;
        Some (Event.Window_requested window)
    | X.Configure_request request ->
        (match Hashtbl.find_opt placed_geom request.id with
        | None -> X.configure display request
        | Some placed ->
            (* Managed geometry belongs to the layout, even for floating clients.
               An ICCCM synthetic reply acknowledges denied configure requests. *)
            X.notify_configure display request.id placed.geometry placed.border_width);
        None
    | X.Unmap_notify (id, synthetic) ->
        let count = Option.value ~default:0 (Hashtbl.find_opt ignore_unmap id) in
        if not synthetic && count > 0 then (
          if count = 1 then Hashtbl.remove ignore_unmap id
          else Hashtbl.replace ignore_unmap id (count - 1);
          None)
        else if Hashtbl.mem managed id then (
          forget ~destroyed:false id;
          Some (Event.Window_unmapped (Window_id.of_int id)))
        else None
    | X.Destroy_notify id ->
        if Hashtbl.mem managed id then (
          forget ~destroyed:true id;
          Some (Event.Window_destroyed (Window_id.of_int id)))
        else None
    | X.Button_press id ->
        (* Thaw/replay even if the grabbed window vanished before dispatch. *)
        X.replay_pointer display;
        if Hashtbl.mem managed id then
          Some (Event.Window_focus_requested (Window_id.of_int id))
        else None
    | X.Key_press binding ->
        let binding = Key.normalize binding in
        if List.exists (Key.equal binding) config.key_grabs then
          Some (Event.Key_pressed binding)
        else None
  in
  Fun.protect ~finally:release_all (fun () ->
    X.grab_keys display config.key_grabs;
    outputs := query_outputs ();
    let windows = X.query_windows display in
    List.iter remember windows;
    let state, commands = init ~outputs:!outputs ~windows in
    let rec loop state commands =
      let running = execute commands in
      (* XNextEvent may use an already buffered event; flush every batch here. *)
      X.flush display;
      if running then
        match decode (X.next_event display) with
        | None -> loop state []
        | Some event ->
            let state, commands = on_event state event in
            loop state commands
    in
    loop state commands)
