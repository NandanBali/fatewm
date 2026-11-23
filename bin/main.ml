(** Entry point wiring [Mlwm_config], pure [Mlwm_core], and [Mlwm_x11_backend]. *)

let () =
  let cfg = Mlwm_config.Config.default in
  let backend_cfg = Mlwm_core.Core.backend_config cfg in
  Mlwm_x11_backend.X11_backend.run backend_cfg
    ~init:(Mlwm_core.Core.init cfg)
    ~on_event:Mlwm_core.Core.step
