(** Pure-OCaml headless display backend for testing and proving [Mlwm_core]
    compiles and runs with zero X11, C, or Unix dependencies. *)

open Mlwm_proto

type trace = {
  init_commands : Command.t list;
  steps : (Event.t * Command.t list) list;
}

type window_state = {
  geometry : Types.Rect.t option;
  border_width : int option;
  visible : bool;
  closed : bool;
}

(** Immutable snapshot of the simulated virtual display. *)
type world

(** {1 Virtual Display Simulation} *)

(** Construct an initial [world] from discovered [outputs] and adopted startup
    [windows]. Adopted windows start visible with their initial geometry and are
    ordered in [stacking_order] from first (top) to last (bottom). *)
val empty_world :
  outputs:Types.Output.t list -> windows:Types.Window_info.t list -> world

(** Apply a single backend command to [world]. *)
val apply_command : world -> Command.t -> world

(** Apply a list of commands in order, stopping immediately if [Quit] or
    [Restart] takes effect. *)
val apply_commands : world -> Command.t list -> world

(** Update [world] for an incoming display event before forwarding to core. *)
val apply_event : world -> Event.t -> world

(** {1 Query Helpers} *)

val window_state : world -> Types.Window_id.t -> window_state option
val window_geometry : world -> Types.Window_id.t -> Types.Rect.t option
val window_border_width : world -> Types.Window_id.t -> int option
val is_visible : world -> Types.Window_id.t -> bool

(** Visible windows in top-to-bottom stacking order. *)
val visible_windows : world -> Types.Window_id.t list

(** Window IDs ordered from top (head) to bottom (tail).
    [Raise_window id] moves [id] to the head of this list. *)
val stacking_order : world -> Types.Window_id.t list

(** [is_above world a b] is [true] iff both [a] and [b] appear in
    [stacking_order world] and [a] is closer to the top than [b]. *)
val is_above : world -> Types.Window_id.t -> Types.Window_id.t -> bool

val focused : world -> Types.Window_id.t option
val closed_windows : world -> Types.Window_id.t list

(** Chronological list of [Spawn] command argument lists. *)
val spawned : world -> string list list

val restarted : world -> bool
val quit : world -> bool
val outputs : world -> Types.Output.t list

(** Flatten [init_commands] followed by all step commands in chronological order. *)
val all_commands : trace -> Command.t list

(** {1 Scripted Runners} *)

(** Run [init] and feed [events] through [on_event], simulating every emitted
    command on the virtual display. Stops processing further events once [Quit]
    or [Restart] is emitted. *)
val run_world :
  outputs:Types.Output.t list ->
  windows:Types.Window_info.t list ->
  events:Event.t list ->
  init:(outputs:Types.Output.t list -> windows:Types.Window_info.t list -> 'state * Command.t list) ->
  on_event:('state -> Event.t -> 'state * Command.t list) ->
  'state * world * trace

(** Backward-compatible runner returning [(final_state, trace)]. *)
val run_script :
  outputs:Types.Output.t list ->
  windows:Types.Window_info.t list ->
  events:Event.t list ->
  init:(outputs:Types.Output.t list -> windows:Types.Window_info.t list -> 'state * Command.t list) ->
  on_event:('state -> Event.t -> 'state * Command.t list) ->
  'state * trace

(** {1 Backend.S Adapter} *)

(** Functor implementing {!Mlwm_proto.Backend.S} over a fixed scripted scenario,
    proving at compile time that [Mlwm_core] runs against the exact same backend
    interface as [X11_backend] with zero X11 dependencies. *)
module Make (_ : sig
  val outputs : Types.Output.t list
  val windows : Types.Window_info.t list
  val events : Event.t list
end) : sig
  include Backend.S

  val last_world : unit -> world option
  val last_trace : unit -> trace option
end
