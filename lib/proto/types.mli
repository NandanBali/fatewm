(** Display-server-agnostic domain types shared across core and backends.
    This library must never depend on X11, Wayland, or any C bindings. *)

module Window_id : sig
  type t = private int

  val of_int : int -> t
  val to_int : t -> int
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Output_id : sig
  type t = private int

  val of_int : int -> t
  val to_int : t -> int
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Rect : sig
  type t = {
    x : int;
    y : int;
    w : int;
    h : int;
  }

  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end

module Color : sig
  (** 24-bit RGB packed as [0xRRGGBB], e.g. [0x5294e2]. *)
  type t = int
end

module Output : sig
  type t = {
    id : Output_id.t;
    name : string;
    geometry : Rect.t;
    primary : bool;
  }

  val equal : t -> t -> bool
end

module Window_info : sig
  type t = {
    id : Window_id.t;
    geometry : Rect.t;
    floating_hint : bool;
        (** True if the display backend classifies this window as a dialog,
            utility, splash, transient, or fixed-size window. *)
    transient_for : Window_id.t option;
  }
end

module Key : sig
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

  (** Deduplicate and canonically sort modifier flags. *)
  val normalize : binding -> binding

  val equal : binding -> binding -> bool
  val compare : binding -> binding -> int
  val pp : Format.formatter -> binding -> unit
end
