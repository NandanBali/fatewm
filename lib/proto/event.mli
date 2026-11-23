(** Events pushed from a display backend into the pure rules core. *)

type t =
  | Output_changed of Types.Output.t list
      (** Full snapshot of active outputs after monitor attach/detach/resize. *)
  | Window_requested of Types.Window_info.t
      (** New managed window asked to be mapped (override-redirect windows are
          never forwarded here). *)
  | Window_unmapped of Types.Window_id.t
      (** Client withdrew/unmapped a window (excluding backend-initiated
          workspace hides). *)
  | Window_destroyed of Types.Window_id.t
      (** Managed window was destroyed. *)
  | Window_focus_requested of Types.Window_id.t
      (** User clicked an unfocused managed window (click-to-focus). *)
  | Window_configure_requested of {
      id : Types.Window_id.t;
      geometry : Types.Rect.t;
    }
      (** A managed client asked to move/resize itself (X ConfigureRequest).
          [geometry] is complete and root-relative (the backend fills fields
          the client left out from the window's current geometry) and excludes
          the border. Requests from unmanaged windows never reach the core. *)
  | Key_pressed of Types.Key.binding
      (** A grabbed keybinding was triggered. *)
