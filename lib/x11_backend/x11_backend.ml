open Mlwm_proto
open Types
module X = Mlwm_x11_c.X11_c

(* The core knows workspaces; these tables know only protocol obligations. *)
type placement = { geometry : Rect.t; border_width : int }

(* Keep maximal screen rectangles: mirrored/nested outputs must not host two
   workspaces over the same area. Sort first so identical snapshots are stable. *)
let clean_outputs outputs =
  let contains (outer : Rect.t) (inner : Rect.t) =
    outer.x <= inner.x && outer.y <= inner.y
    && outer.x + outer.w >= inner.x + inner.w
    && outer.y + outer.h >= inner.y + inner.h
  in
  let rec insert (candidate : Output.t) = function
    | [] -> [candidate]
    | (kept : Output.t) :: rest ->
        if Rect.equal kept.geometry candidate.geometry then
          (if candidate.primary && not kept.primary then candidate else kept) :: rest
        else if contains kept.geometry candidate.geometry then
          { kept with primary = kept.primary || candidate.primary } :: rest
        else if contains candidate.geometry kept.geometry then
          insert { candidate with primary = candidate.primary || kept.primary } rest
        else kept :: insert candidate rest
  in
  let by_id (a : Output.t) (b : Output.t) = Output_id.compare a.id b.id in
  List.sort by_id outputs
  |> List.fold_left (fun kept output -> insert output kept) []
  |> List.sort by_id

let run (config : Backend.config) ~init ~on_event =
  let display = X.open_display () in
  let managed = Hashtbl.create 32 in
  let placed_geom = Hashtbl.create 32 in
  let ignore_unmap = Hashtbl.create 32 in
  let focused = ref None in
  let pending_configure = ref None in
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
    if Hashtbl.mem managed id then true
    else match X.manage display id with
      | None -> false
      | Some (geometry, border_width) ->
          Hashtbl.add managed id ();
          (* Before the first Place, only the client's real border is valid. *)
          Hashtbl.replace placed_geom id { geometry; border_width };
          true
  in
  let forget ~destroyed id =
    (* Metadata is always removed; destroyed windows need no server cleanup. *)
    X.unmanage display id destroyed;
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
    if previous <> target then (
      Option.iter (fun id -> decorate id false) previous;
      Option.iter (fun id -> decorate id true) target);
    (* Repeated Focus is deliberately forced by the core (e.g. after a click). *)
    X.focus display target
  in
  let rec execute = function
    | [] -> true
    | Command.Quit :: _ -> false
    | Command.Restart :: rest ->
        (match (try Unix.access Sys.executable_name [Unix.X_OK]; Ok ()
                with exn -> Error exn) with
        | Error exn ->
            Printf.eprintf "mlwm: restart refused for %s: %s\n%!"
              Sys.executable_name (Printexc.to_string exn);
            execute rest
        | Ok () ->
            X.flush display;
            release_all ();
            try Unix.execv Sys.executable_name Sys.argv with exn ->
              Printf.eprintf "mlwm: restart exec failed for %s: %s; exiting\n%!"
                Sys.executable_name (Printexc.to_string exn);
              exit 1)
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
    X.query_outputs display |> clean_outputs
  in
  let decode = function
    | X.Ignored -> None
    | X.Mapping_changed -> X.grab_keys display config.key_grabs; None
    | X.Outputs_changed ->
        let current = query_outputs () in
        if List.equal Output.equal !outputs current then None
        else (outputs := current; Some (Event.Output_changed current))
    | X.Map_request window ->
        if remember window then Some (Event.Window_requested window) else None
    | X.Configure_request request ->
        (match Hashtbl.find_opt placed_geom request.id with
        | None -> X.configure display request; None
        | Some placed ->
            let current = match X.geometry display request.id with
              | None -> placed.geometry
              | Some (geometry, _) -> geometry
            in
            let field bit requested previous =
              if request.mask land bit <> 0 then requested else previous
            in
            let geometry = {
              Rect.x = field 1 request.x current.x;
              y = field 2 request.y current.y;
              w = field 4 request.width current.w;
              h = field 8 request.height current.h;
            } in
            (* Border/stacking requests are layout-owned; only client geometry
               crosses Proto. Acknowledge AFTER the returned commands run. *)
            pending_configure := Some request.id;
            Some (Event.Window_configure_requested {
              id = Window_id.of_int request.id; geometry }))
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
    let windows = X.query_windows display |> List.filter remember in
    let state, commands = init ~outputs:!outputs ~windows in
    let rec loop state commands =
      let running = execute commands in
      let reply = !pending_configure in
      pending_configure := None;
      if not !closed then (
        Option.iter (fun id ->
          if Hashtbl.mem managed id then
            match X.geometry display id with
            | None -> () (* The client may have died while commands ran. *)
            | Some (geometry, border_width) ->
                let placed = { geometry; border_width } in
                Hashtbl.replace placed_geom id placed;
                X.notify_configure display id placed.geometry placed.border_width) reply;
        (* XNextEvent may use a buffered event; flush every batch here. *)
        X.flush display);
      if running then
        match decode (X.next_event display) with
        | None -> loop state []
        | Some event ->
            let state, commands = on_event state event in
            loop state commands
    in
    loop state commands)
