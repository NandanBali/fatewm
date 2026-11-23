type t =
  | Output_changed of Types.Output.t list
  | Window_requested of Types.Window_info.t
  | Window_unmapped of Types.Window_id.t
  | Window_destroyed of Types.Window_id.t
  | Window_focus_requested of Types.Window_id.t
  | Key_pressed of Types.Key.binding
