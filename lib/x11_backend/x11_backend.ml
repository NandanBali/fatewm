(* M0 placeholder — implemented in M1/M2 by the X11/C agent. *)

let run _config ~init ~on_event:_ =
  ignore (Mlwm_x11_c.X11_c.stub_ping ());
  let _state, _cmds = init ~outputs:[] ~windows:[] in
  failwith "X11_backend.run: not yet implemented (M1)"
