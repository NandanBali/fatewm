(** Small, typed boundary around Xlib. The display is owned by a C custom block;
    callers must serialize access and must not close it during [next_event]. *)
open Mlwm_proto.Types

type t

type configure = {
  id : int;
  x : int;
  y : int;
  width : int;
  height : int;
  border_width : int;
  above : int;
  detail : int;
  mask : int;
}

(* Constructor order and record field order are mirrored in x11_stubs.c. *)
type event =
  | Ignored
  | Outputs_changed
  | Mapping_changed
  | Map_request of Window_info.t
  | Configure_request of configure
  | Unmap_notify of int * bool
  | Destroy_notify of int
  | Button_press of int
  | Key_press of Key.binding

external open_display : unit -> t = "mlwm_x11_open"
external close : t -> unit = "mlwm_x11_close"
external flush : t -> unit = "mlwm_x11_flush"
external query_outputs : t -> Output.t list = "mlwm_x11_outputs"
external query_windows : t -> Window_info.t list = "mlwm_x11_windows"
external grab_keys : t -> Key.binding list -> unit = "mlwm_x11_grab_keys"
external next_event : t -> event = "mlwm_x11_next_event"
external configure : t -> configure -> unit = "mlwm_x11_configure"
external notify_configure : t -> int -> Rect.t -> int -> unit
  = "mlwm_x11_notify_configure"
external place : t -> int -> Rect.t -> int -> Color.t -> unit = "mlwm_x11_place"
external decorate : t -> int -> Color.t -> bool -> unit = "mlwm_x11_decorate"
external focus : t -> int option -> unit = "mlwm_x11_focus"
external replay_pointer : t -> unit = "mlwm_x11_replay_pointer"
external show : t -> int -> unit = "mlwm_x11_show"
(* False means it was already unmapped: no UnmapNotify will be generated. *)
external hide : t -> int -> bool = "mlwm_x11_hide"
external raise_window : t -> int -> unit = "mlwm_x11_raise"
external close_window : t -> int -> unit = "mlwm_x11_close_window"
external spawn : string array -> unit = "mlwm_x11_spawn"

(** Save-set membership lets the server remap hidden clients after a crash. *)
external manage : t -> int -> unit = "mlwm_x11_manage"
external unmanage : t -> int -> unit = "mlwm_x11_unmanage"
external release : t -> int -> unit = "mlwm_x11_release"
external sync : t -> unit = "mlwm_x11_sync"
