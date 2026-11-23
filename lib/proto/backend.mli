(** Signature implemented by every display backend (X11, Fake, future wlroots).
    The backend owns the event loop so push-based compositors like wlroots fit
    without changing [lib/core] or [bin/main.ml]. *)

type config = {
  key_grabs : Types.Key.binding list;
  border_width : int;
  border_focused : Types.Color.t;
  border_unfocused : Types.Color.t;
}

(** Obligations every backend has towards the core:

    - {b Own hides are invisible.} [Hide_window] must not produce a
      [Window_unmapped]. The X11 backend counts its own unmaps per window
      ([ignore_unmap]): increment when [Hide_window] actually unmaps a mapped
      window, consume one count per non-synthetic UnmapNotify, always forward
      a synthetic UnmapNotify (ICCCM withdraw), and reset the count when the
      window is withdrawn or destroyed. The mapped-state check and the unmap
      must be atomic with respect to the client's own unmap.
    - {b Exactly once.} A managed window yields at most one of
      [Window_unmapped] / [Window_destroyed] per lifetime; afterwards it is
      unmanaged and further events for it are dropped.
    - {b Map requests are the core's to grant.} [Window_requested] may repeat
      for a window that is already managed; the backend never maps a window
      itself in response, so a window on a hidden workspace stays hidden.
    - {b Configure requests are always answered.} After running the commands
      the core returned for a [Window_configure_requested], the backend sends
      the client a synthetic ConfigureNotify with the window's current
      geometry and border (ICCCM 4.1.5), whether or not the core moved it.
    - {b Commands may name dead windows.} A command for a window that was
      destroyed concurrently is a silent no-op, never an error that stops the
      loop. *)

module type S = sig
  val run :
    config ->
    init:(outputs:Types.Output.t list -> windows:Types.Window_info.t list -> 'state * Command.t list) ->
    on_event:('state -> Event.t -> 'state * Command.t list) ->
    unit
end
