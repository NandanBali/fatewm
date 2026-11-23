module Window_id = struct
  type t = int

  let of_int x = x
  let to_int x = x
  let equal = Int.equal
  let compare = Int.compare
  let pp fmt x = Format.fprintf fmt "win#0x%x" x
end

module Output_id = struct
  type t = int

  let of_int x = x
  let to_int x = x
  let equal = Int.equal
  let compare = Int.compare
  let pp fmt x = Format.fprintf fmt "out#%d" x
end

module Rect = struct
  type t = {
    x : int;
    y : int;
    w : int;
    h : int;
  }

  let equal a b = a.x = b.x && a.y = b.y && a.w = b.w && a.h = b.h

  let pp fmt r = Format.fprintf fmt "%dx%d+%d+%d" r.w r.h r.x r.y
end

module Color = struct
  type t = int
end

module Output = struct
  type t = {
    id : Output_id.t;
    name : string;
    geometry : Rect.t;
    primary : bool;
  }

  let equal a b =
    Output_id.equal a.id b.id
    && String.equal a.name b.name
    && Rect.equal a.geometry b.geometry
    && Bool.equal a.primary b.primary
end

module Window_info = struct
  type t = {
    id : Window_id.t;
    geometry : Rect.t;
    floating_hint : bool;
    transient_for : Window_id.t option;
  }
end

module Key = struct
  type mod_ =
    | Super
    | Alt
    | Shift
    | Ctrl

  type sym =
    | Return
    | Tab
    | Space
    | Escape
    | Backspace
    | Left
    | Right
    | Up
    | Down
    | Char of char

  type binding = {
    mods : mod_ list;
    sym : sym;
  }

  let mod_rank = function
    | Super -> 0
    | Alt -> 1
    | Ctrl -> 2
    | Shift -> 3

  let compare_mod a b = Int.compare (mod_rank a) (mod_rank b)

  let sym_rank = function
    | Return -> 0
    | Tab -> 1
    | Space -> 2
    | Escape -> 3
    | Backspace -> 4
    | Left -> 5
    | Right -> 6
    | Up -> 7
    | Down -> 8
    | Char _ -> 9

  let compare_sym a b =
    match (a, b) with
    | Char ca, Char cb -> Char.compare ca cb
    | _ -> Int.compare (sym_rank a) (sym_rank b)

  let normalize b =
    let mods = List.sort_uniq compare_mod b.mods in
    { b with mods }

  let compare a b =
    let a = normalize a and b = normalize b in
    let c = compare_sym a.sym b.sym in
    if c <> 0 then c else List.compare compare_mod a.mods b.mods

  let equal a b = compare a b = 0

  let string_of_mod = function
    | Super -> "Super"
    | Alt -> "Alt"
    | Shift -> "Shift"
    | Ctrl -> "Ctrl"

  let string_of_sym = function
    | Return -> "Return"
    | Tab -> "Tab"
    | Space -> "Space"
    | Escape -> "Escape"
    | Backspace -> "Backspace"
    | Left -> "Left"
    | Right -> "Right"
    | Up -> "Up"
    | Down -> "Down"
    | Char c -> String.make 1 c

  let pp fmt b =
    let b = normalize b in
    let parts = List.map string_of_mod b.mods @ [ string_of_sym b.sym ] in
    Format.pp_print_string fmt (String.concat "+" parts)
end
