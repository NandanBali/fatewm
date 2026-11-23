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
  | Close_window of Types.Window_id.t
  | Spawn of string list
  | Restart
  | Quit

let equal a b =
  match (a, b) with
  | Place_window x, Place_window y ->
    Types.Window_id.equal x.id y.id
    && Types.Rect.equal x.geometry y.geometry
    && x.border_width = y.border_width
  | Show_window a, Show_window b
  | Hide_window a, Hide_window b
  | Raise_window a, Raise_window b
  | Close_window a, Close_window b ->
    Types.Window_id.equal a b
  | Focus_window a, Focus_window b -> Option.equal Types.Window_id.equal a b
  | Spawn a, Spawn b -> List.equal String.equal a b
  | Restart, Restart | Quit, Quit -> true
  | _ -> false

let pp fmt = function
  | Place_window { id; geometry; border_width } ->
    Format.fprintf fmt "Place(%a, %a, bw=%d)" Types.Window_id.pp id
      Types.Rect.pp geometry border_width
  | Show_window id -> Format.fprintf fmt "Show(%a)" Types.Window_id.pp id
  | Hide_window id -> Format.fprintf fmt "Hide(%a)" Types.Window_id.pp id
  | Raise_window id -> Format.fprintf fmt "Raise(%a)" Types.Window_id.pp id
  | Focus_window None -> Format.pp_print_string fmt "Focus(none)"
  | Focus_window (Some id) ->
    Format.fprintf fmt "Focus(%a)" Types.Window_id.pp id
  | Close_window id -> Format.fprintf fmt "Close(%a)" Types.Window_id.pp id
  | Spawn argv ->
    Format.fprintf fmt "Spawn([%s])" (String.concat "; " argv)
  | Restart -> Format.pp_print_string fmt "Restart"
  | Quit -> Format.pp_print_string fmt "Quit"
