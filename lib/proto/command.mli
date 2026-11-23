(** Commands emitted by the pure rules core for a display backend to apply. *)

type t =
  | Place_window of {
      id : Types.Window_id.t;
      geometry : Types.Rect.t;
      border_width : int;
    }
  | Show_window of Types.Window_id.t
  | Hide_window of Types.Window_id.t
  | Raise_window of Types.Window_id.t
  | Focus_window of Types.Window_id.t option
      (** Focus [Some w] (updating focused/unfocused borders) or clear focus. *)
  | Close_window of Types.Window_id.t
      (** Request graceful close (e.g. WM_DELETE_WINDOW), falling back to kill. *)
  | Spawn of string list
      (** Fork/exec argv (e.g. [["xterm"]] or [["rofi"; "-show"; "drun"]]). *)
  | Restart
      (** Re-exec the [mlwm] binary in place; startup re-adopts live windows. *)
  | Quit
      (** Exit the backend event loop cleanly. *)

val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
