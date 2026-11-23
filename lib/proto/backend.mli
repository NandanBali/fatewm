(** Signature implemented by every display backend (X11, Fake, future wlroots).
    The backend owns the event loop so push-based compositors like wlroots fit
    without changing [lib/core] or [bin/main.ml]. *)

type config = {
  key_grabs : Types.Key.binding list;
  border_width : int;
  border_focused : Types.Color.t;
  border_unfocused : Types.Color.t;
}

module type S = sig
  val run :
    config ->
    init:(outputs:Types.Output.t list -> windows:Types.Window_info.t list -> 'state * Command.t list) ->
    on_event:('state -> Event.t -> 'state * Command.t list) ->
    unit
end
