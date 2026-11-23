(** Tiling layouts and the pure geometry math behind them.

    Everything here is a plain function from (layout, screen area, window count)
    to rectangles — no state, no window ids — so it can be unit-tested with
    nothing but integers. *)

open Mlwm_proto.Types

type t =
  | Tall of { master_ratio : float }
      (** Master column on the left taking [master_ratio] of the width; the
          remaining windows share the right column, stacked vertically. *)
  | Monocle  (** Every tiled window fills the whole screen; focus is on top. *)

let min_ratio = 0.1
let max_ratio = 0.9

(* [Float.min]/[Float.max] would propagate a NaN ratio; falling back to the
   midpoint keeps a broken config from producing garbage geometry. *)
let clamp_ratio r =
  if Float.is_nan r then 0.5 else Float.min max_ratio (Float.max min_ratio r)

let resize delta = function
  | Tall { master_ratio } ->
      Tall { master_ratio = clamp_ratio (master_ratio +. delta) }
  | Monocle -> Monocle

(** [Tall <-> Monocle]. Coming back from Monocle restarts at the configured
    default ratio, since Monocle carries no ratio of its own. *)
let cycle ~default_ratio = function
  | Tall _ -> Monocle
  | Monocle -> Tall { master_ratio = clamp_ratio default_ratio }

(* X11 draws a window's border *outside* its w×h, so a window placed at
   (x, y) with size (w - 2bw) × (h - 2bw) and border bw exactly fills a
   w × h cell. Sizes are clamped to 1 because X rejects zero-sized windows. *)
let inset ~border_width (r : Rect.t) : Rect.t =
  {
    r with
    w = max 1 (r.w - (2 * border_width));
    h = max 1 (r.h - (2 * border_width));
  }

(* Split [total] pixels into [n] near-equal parts. The first [total mod n]
   parts get one extra pixel, so the parts sum to exactly [total]: no gap at
   the bottom of the stack and no overlap. *)
let split total n =
  List.init n (fun i -> (total / n) + if i < total mod n then 1 else 0)

(* Outer cells (borders included) for [n >= 1] windows in Tall. *)
let tall_cells ratio (area : Rect.t) n : Rect.t list =
  if n = 1 then [ area ]
  else
    (* Keep both columns at least 1px wide whenever the area allows it. *)
    let master_w =
      int_of_float (float_of_int area.w *. ratio) |> min (area.w - 1) |> max 1
    in
    let stack_w = max 1 (area.w - master_w) in
    let _, stack =
      List.fold_left_map
        (fun y h -> (y + h, { Rect.x = area.x + master_w; y; w = stack_w; h }))
        area.y
        (split area.h (n - 1))
    in
    { area with w = master_w } :: stack

(** Window rectangles (border already subtracted) for the [n] tiled windows of a
    workspace, in tiled order: the first rect is the master. *)
let arrange layout ~border_width (area : Rect.t) n : Rect.t list =
  if n <= 0 then []
  else
    let cells =
      match layout with
      | Tall { master_ratio } -> tall_cells (clamp_ratio master_ratio) area n
      | Monocle -> List.init n (fun _ -> area)
    in
    List.map (inset ~border_width) cells

let default_float_w = 640
let default_float_h = 480

(** Centre a [w × h] client (plus its border) inside [area]. The result is
    relative to [area]'s origin, which is how floating rects are stored: a
    floating window then follows its workspace when it moves between outputs.
    Non-positive sizes fall back to 640x480; sizes are clamped to fit. *)
let center ~border_width (area : Rect.t) ~w ~h : Rect.t =
  let w, h =
    if w <= 0 || h <= 0 then (default_float_w, default_float_h) else (w, h)
  in
  let bw2 = 2 * border_width in
  let w = max 1 (min w (area.w - bw2)) and h = max 1 (min h (area.h - bw2)) in
  {
    x = max 0 ((area.w - w - bw2) / 2);
    y = max 0 ((area.h - h - bw2) / 2);
    w;
    h;
  }
