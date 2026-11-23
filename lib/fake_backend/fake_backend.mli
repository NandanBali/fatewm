(** Pure-OCaml headless display backend for testing and proving [Mlwm_core]
    compiles and runs with zero X11 dependencies. *)

open Mlwm_proto

type trace = {
  init_commands : Command.t list;
  steps : (Event.t * Command.t list) list;
}

val run_script :
  outputs:Types.Output.t list ->
  windows:Types.Window_info.t list ->
  events:Event.t list ->
  init:(outputs:Types.Output.t list -> windows:Types.Window_info.t list -> 'state * Command.t list) ->
  on_event:('state -> Event.t -> 'state * Command.t list) ->
  'state * trace
