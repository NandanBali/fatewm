open Mlwm_proto
module Fake = Mlwm_fake_backend.Fake_backend

let id n = Types.Window_id.of_int n
let rect = { Types.Rect.x = 0; y = 0; w = 640; h = 480 }
let info n = { Types.Window_info.id = id n; geometry = rect; floating_hint = false; transient_for = None }

let output =
  { Types.Output.id = Types.Output_id.of_int 1; name = "test"; geometry = rect; primary = true }

let assert_error_commands world expected =
  let actual = Fake.errors world in
  assert (List.length actual = List.length expected);
  List.iter2 (fun got want -> assert (Command.equal got want)) actual expected

let test_duplicate_requests_preserve_state () =
  let shown = Fake.empty_world ~outputs:[ output ] ~windows:[ info 1 ] in
  let shown = Fake.apply_command shown (Command.Focus_window (Some (id 1))) in
  let shown = Fake.apply_command shown (Command.Close_window (id 1)) in
  let shown = Fake.apply_event shown (Event.Window_requested { (info 1) with geometry = { rect with w = 777 } }) in
  assert (Fake.is_visible shown (id 1));
  assert (Fake.window_geometry shown (id 1) = Some rect);
  assert (Fake.focused shown = Some (id 1));
  assert (Fake.closed_windows shown = [ id 1 ]);
  assert_error_commands shown [];

  let hidden = Fake.apply_event (Fake.empty_world ~outputs:[ output ] ~windows:[ info 2 ]) (Event.Window_unmapped (id 2)) in
  let hidden = Fake.apply_event hidden (Event.Window_requested { (info 2) with geometry = { rect with h = 333 } }) in
  assert (not (Fake.is_visible hidden (id 2)));
  assert (Fake.window_geometry hidden (id 2) = Some rect);
  assert_error_commands hidden []

let test_hide_focused_clears_focus () =
  let world = Fake.empty_world ~outputs:[ output ] ~windows:[ info 1 ] in
  let world = Fake.apply_command world (Command.Focus_window (Some (id 1))) in
  let world = Fake.apply_command world (Command.Hide_window (id 1)) in
  assert (Fake.focused world = None);
  assert_error_commands world []

let test_invalid_focus_is_recorded () =
  let world = Fake.empty_world ~outputs:[ output ] ~windows:[ info 1; info 2 ] in
  let world = Fake.apply_command world (Command.Hide_window (id 1)) in
  let world = Fake.apply_command world (Command.Focus_window (Some (id 2))) in
  let hidden = Fake.apply_command world (Command.Focus_window (Some (id 1))) in
  let unknown = Fake.apply_command world (Command.Focus_window (Some (id 99))) in
  assert (Fake.focused hidden = Some (id 2));
  assert (Fake.focused unknown = Some (id 2));
  assert_error_commands hidden [ Command.Focus_window (Some (id 1)) ];
  assert_error_commands unknown [ Command.Focus_window (Some (id 99)) ]

let test_commands_after_destroy_are_errors_without_resurrection () =
  let world = Fake.empty_world ~outputs:[ output ] ~windows:[ info 1 ] in
  let world = Fake.apply_event world (Event.Window_destroyed (id 1)) in
  let place = Command.Place_window { id = id 1; geometry = rect; border_width = 2 } in
  let commands = [ Command.Show_window (id 1); place; Command.Raise_window (id 1); Command.Close_window (id 1) ] in
  let world = Fake.apply_commands world commands in
  assert_error_commands world commands;
  assert (not (Fake.is_visible world (id 1)));
  assert (Fake.stacking_order world = []);
  assert (Fake.closed_windows world = [])

let test_unknown_window_commands_are_errors () =
  let world = Fake.empty_world ~outputs:[ output ] ~windows:[] in
  let commands =
    [ Command.Show_window (id 42);
      Command.Place_window { id = id 42; geometry = rect; border_width = 1 };
      Command.Raise_window (id 42);
      Command.Close_window (id 42) ]
  in
  let world = Fake.apply_commands world commands in
  assert_error_commands world commands;
  assert (Fake.window_state world (id 42) = None)

let test_core_and_fake_backend_invariants () =
  let cfg =
    { Mlwm_core.Core.Config.workspaces = 3; border_width = 2;
      border_focused = 0x5294e2; border_unfocused = 0x3b4252;
      default_master_ratio = 0.55; keys = [] }
  in
  let events =
    [ Event.Window_requested (info 1);
      Event.Window_requested (info 2);
      Event.Window_requested (info 1);
      Event.Window_focus_requested (id 1);
      Event.Window_unmapped (id 2);
      Event.Window_destroyed (id 2);
      Event.Window_unmapped (id 1) ]
  in
  let check events =
    let core, world, _trace =
      Fake.run_world ~outputs:[ output ] ~windows:[] ~events
        ~init:(Mlwm_core.Core.init cfg) ~on_event:Mlwm_core.Core.step
    in
    assert_error_commands world [];
    List.iter
      (fun n -> assert (Mlwm_core.Core.is_visible core (id n) = Fake.is_visible world (id n)))
      [ 1; 2 ];
    match Fake.focused world with
    | None -> ()
    | Some focused -> assert (Fake.is_visible world focused)
  in
  let rec check_prefixes rev_prefix = function
    | [] -> check (List.rev rev_prefix)
    | event :: rest ->
      check (List.rev rev_prefix);
      check_prefixes (event :: rev_prefix) rest
  in
  check_prefixes [] events

let () =
  test_duplicate_requests_preserve_state ();
  test_hide_focused_clears_focus ();
  test_invalid_focus_is_recorded ();
  test_commands_after_destroy_are_errors_without_resurrection ();
  test_unknown_window_commands_are_errors ();
  test_core_and_fake_backend_invariants ();
  print_endline "fake backend regression tests passed"
