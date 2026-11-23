(* Core tests: M0 smoke test plus regression tests for focus/raise diffing,
   idempotent output snapshots and render-time float clamping. Plain OCaml, no
   test framework. *)

open Mlwm_proto
module Core = Mlwm_core.Core

let failures = ref 0
let total = ref 0

let check name cond =
  incr total;
  if not cond then begin
    incr failures;
    Printf.eprintf "FAIL: %s\n%!" name
  end

let wid = Types.Window_id.of_int
let oid = Types.Output_id.of_int
let rect x y w h = { Types.Rect.x; y; w; h }
let bw = 2
let key c = { Types.Key.mods = [ Types.Key.Super ]; sym = Types.Key.Char c }

let cfg =
  {
    Core.Config.workspaces = 9;
    border_width = bw;
    border_focused = 0x5294e2;
    border_unfocused = 0x3b4252;
    default_master_ratio = 0.55;
    keys =
      [
        (key 'j', Core.Action.Focus Core.Action.Next);
        (key '1', Core.Action.View_workspace 1);
        (key '2', Core.Action.View_workspace 2);
        (key 'm', Core.Action.Move_to_workspace 2);
        (key 'o', Core.Action.Move_to_output Core.Action.Next);
        (key 'p', Core.Action.Move_to_output Core.Action.Prev);
        (key 'f', Core.Action.Focus_output Core.Action.Next);
      ];
  }

let output id name geometry primary =
  { Types.Output.id = oid id; name; geometry; primary }

let single = output 1 "test-0" (rect 0 0 1280 720) true
let left = output 1 "L" (rect 0 0 1280 720) true
let right = output 2 "R" (rect 1280 0 1280 720) false

let info ?(floating = false) id geometry =
  {
    Types.Window_info.id = wid id;
    geometry;
    floating_hint = floating;
    transient_for = None;
  }

let a = wid 1
and c = wid 3

let plain id = info id (rect 0 0 400 300)
let press st ch = Core.step st (Event.Key_pressed (key ch))

let has_focus = List.exists (function Command.Focus_window _ -> true | _ -> false)
let has_raise = List.exists (function Command.Raise_window _ -> true | _ -> false)

let place_of w cmds =
  List.fold_left
    (fun acc -> function
      | Command.Place_window { id; geometry; _ } when id = w -> Some geometry
      | _ -> acc)
    None cmds

let inside ~out r =
  r.Types.Rect.x >= out.Types.Rect.x
  && r.y >= out.y
  && r.x + r.w + (2 * bw) <= out.x + out.w
  && r.y + r.h + (2 * bw) <= out.y + out.h

let two_win_state () =
  fst (Core.init cfg ~outputs:[ single ] ~windows:[ plain 1; plain 2 ])

(* --- M0 smoke --- *)
let test_smoke () =
  let cfg0 = { cfg with keys = [] } in
  let _st, trace =
    Mlwm_fake_backend.Fake_backend.run_script ~outputs:[ single ] ~windows:[]
      ~events:[] ~init:(Core.init cfg0) ~on_event:Core.step
  in
  check "smoke: no steps" (trace.steps = [])

(* --- Rofi scenario --- *)
let rofi_state () =
  let st = two_win_state () in
  check "rofi: A focused at init" (Core.focused st = Some a);
  let st, _ = Core.step st (Event.Window_requested (plain 3)) in
  check "rofi: C focused after request" (Core.focused st = Some c);
  let st, _ = press st 'm' in
  check "rofi: C on ws2" (Core.workspace_of st c = Some 2);
  check "rofi: focus back to A" (Core.focused st = Some a);
  st

let test_rofi () =
  let st = rofi_state () in
  let quiet name cmds =
    check (name ^ ": no Focus_window") (not (has_focus cmds));
    check (name ^ ": no Raise_window") (not (has_raise cmds))
  in
  let _, cmds = Core.step st (Event.Window_destroyed c) in
  quiet "destroy C" cmds;
  let _, cmds = Core.step st (Event.Window_unmapped c) in
  quiet "unmap hidden C" cmds;
  let _, cmds = Core.step st (Event.Output_changed [ single ]) in
  check "identical Output_changed emits []" (cmds = []);
  (* (d) reordered outputs *)
  let st2, _ = Core.init cfg ~outputs:[ left; right ] ~windows:[ plain 1 ] in
  let _, cmds = Core.step st2 (Event.Output_changed [ left; right ]) in
  check "same snapshot, same order emits []" (cmds = []);
  let _, cmds = Core.step st2 (Event.Output_changed [ right; left ]) in
  check "reordered snapshot emits []" (cmds = []);
  (* (e) unmap on the other visible output *)
  let st2, _ = press st2 'f' in
  let st2, _ = Core.step st2 (Event.Window_requested (plain 5)) in
  let st2, _ = press st2 'f' in
  check "other-output: X on other output"
    (Core.workspace_of st2 (wid 5) <> Core.current_workspace st2);
  let st3, cmds = Core.step st2 (Event.Window_unmapped (wid 5)) in
  check "unmap on other output: no Focus_window" (not (has_focus cmds));
  check "unmap on other output: focus unchanged"
    (Core.focused st3 = Core.focused st2);
  (* (f) hidden destroy with visible float *)
  let st = rofi_state () in
  let st, _ =
    Core.step st (Event.Window_requested (info ~floating:true 6 (rect 0 0 300 200)))
  in
  check "float visible" (Core.is_floating st (wid 6) && Core.is_visible st (wid 6));
  let _, cmds = Core.step st (Event.Window_destroyed c) in
  check "destroy hidden with visible float: no Raise_window" (not (has_raise cmds));
  check "destroy hidden with visible float: no Focus_window" (not (has_focus cmds))

(* --- clicks --- *)
let test_click () =
  let st = two_win_state () in
  let f = Option.get (Core.focused st) in
  let _, cmds = Core.step st (Event.Window_focus_requested f) in
  check "click on focused window emits Focus_window"
    (List.mem (Command.Focus_window (Some f)) cmds);
  (* raises only exist for floats / Monocle; click must force them *)
  let st, _ =
    Core.step st (Event.Window_requested (info ~floating:true 6 (rect 0 0 300 200)))
  in
  let _, cmds = Core.step st (Event.Window_focus_requested (wid 6)) in
  check "click on focused float emits Focus_window"
    (List.mem (Command.Focus_window (Some (wid 6))) cmds);
  check "click on focused float emits Raise_window"
    (List.mem (Command.Raise_window (wid 6)) cmds)

(* --- key-driven focus --- *)
let test_keys () =
  let st = two_win_state () in
  let st1, cmds = press st '2' in
  check "View 2 emits Focus_window" (has_focus cmds);
  let _, cmds = press st1 '1' in
  check "View 1 emits Focus_window" (has_focus cmds);
  let _, cmds = press st '1' in
  check "View current workspace emits []" (cmds = []);
  let _, cmds = press st 'j' in
  check "Focus Next, two windows" (has_focus cmds);
  let one, _ = Core.init cfg ~outputs:[ single ] ~windows:[ plain 1 ] in
  let _, cmds = press one 'j' in
  check "Focus Next, one window (forced)"
    (List.mem (Command.Focus_window (Some a)) cmds);
  let _, init_cmds = Core.init cfg ~outputs:[ single ] ~windows:[ plain 1 ] in
  check "init ends with Focus_window"
    (match List.rev init_cmds with Command.Focus_window _ :: _ -> true | _ -> false)

(* --- float clamp --- *)
let dp = output 1 "DP" (rect 0 0 3840 2160) true
let hdmi = output 2 "HDMI" (rect 3840 0 1366 768) false
let f = wid 10
let float_info = info ~floating:true 10 (rect 0 0 800 600)

let float_state () =
  let st, _ = Core.init cfg ~outputs:[ dp; hdmi ] ~windows:[] in
  let st, cmds = Core.step st (Event.Window_requested float_info) in
  check "float: placed centered on DP"
    (place_of f cmds = Some (rect 1518 778 800 600));
  st

let test_float_move () =
  let st = float_state () in
  let st, cmds = press st 'o' in
  let r = place_of f cmds in
  check "move to HDMI: clamped rect" (r = Some (rect 4402 164 800 600));
  check "move to HDMI: inside output"
    (match r with Some r -> inside ~out:hdmi.geometry r | None -> false);
  check "geometry reports clamped rect" (Core.geometry st f = r);
  (* restore: focus HDMI, move back to DP *)
  let st, _ = press st 'f' in
  let _, cmds = press st 'p' in
  check "restore after Move_to_output"
    (place_of f cmds = Some (rect 1518 778 800 600))

let test_float_shrink () =
  let st = float_state () in
  let small = output 1 "DP" (rect 0 0 1000 500) true in
  let st, cmds = Core.step st (Event.Output_changed [ small; hdmi ]) in
  let r = place_of f cmds in
  check "shrink: clamped rect" (r = Some (rect 196 0 800 496));
  check "shrink: inside output"
    (match r with Some r -> inside ~out:small.geometry r | None -> false);
  let _, cmds = Core.step st (Event.Output_changed [ dp; hdmi ]) in
  check "restore after growing output"
    (place_of f cmds = Some (rect 1518 778 800 600))

let () =
  test_smoke ();
  test_rofi ();
  test_click ();
  test_keys ();
  test_float_move ();
  test_float_shrink ();
  if !failures > 0 then begin
    Printf.eprintf "%d/%d checks failed\n" !failures !total;
    exit 1
  end;
  Printf.printf "mlwm core tests passed (%d checks)\n" !total
