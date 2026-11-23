(** Raw OCaml external declarations backed by [cbits/x11_stubs.c]. *)

external stub_ping : unit -> int = "mlwm_x11_stub_ping"
