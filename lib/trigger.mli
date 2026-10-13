(** The condition of a trigger order: a take-profit or stop-loss that waits off the book
    until the mark price reaches [trigger_px], then is placed as an ordinary order.

    Which way the mark has to move depends on the order's side:
    - a sell stop-loss and a buy take-profit fire when the mark is at or below
      [trigger_px] (closing a long at a loss, or a short at a profit);
    - a buy stop-loss and a sell take-profit fire when the mark is at or above it. *)

open! Core

module Kind : sig
  type t =
    | Take_profit
    | Stop_loss
  [@@deriving sexp, compare, equal, hash, enumerate]
end

type t =
  { trigger_px : Price.t
  ; kind : Kind.t
  }
[@@deriving sexp, compare, equal]

(** [true] when the order fires on a mark at or above [trigger_px], [false] when at or
    below. *)
val fires_above : t -> side:Side.t -> bool

(** Whether a mark of [mark] fires an order on [side]. *)
val fires : t -> side:Side.t -> mark:Price.t -> bool
