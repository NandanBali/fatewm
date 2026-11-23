(* M0 zero-X11 smoke test — expanded in M1/M2 by the Tests agent. *)

open Mlwm_proto

let () =
  let cfg =
    {
      Mlwm_core.Core.Config.workspaces = 9;
      border_width = 2;
      border_focused = 0x5294e2;
      border_unfocused = 0x3b4252;
      default_master_ratio = 0.55;
      keys = [];
    }
  in
  let out0 =
    {
      Types.Output.id = Types.Output_id.of_int 1;
      name = "test-0";
      geometry = { Types.Rect.x = 0; y = 0; w = 1280; h = 720 };
      primary = true;
    }
  in
  let _st, trace =
    Mlwm_fake_backend.Fake_backend.run_script ~outputs:[ out0 ] ~windows:[]
      ~events:[] ~init:(Mlwm_core.Core.init cfg) ~on_event:Mlwm_core.Core.step
  in
  assert (trace.steps = []);
  print_endline "mlwm M0 core smoke test passed"
