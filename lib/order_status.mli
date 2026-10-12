(** Outcome of placing an order.

    An order that rests (even after partial fills) is [Resting]; an IOC or market order
    with any fill is [Filled] with the filled size and average price; anything else is
    [Rejected]. *)

open! Core

type t =
  | Resting of
      { order_id : Order_id.t
      ; client_order_id : Client_order_id.t option
      }
  | Filled of
      { order_id : Order_id.t
      ; total : Size.t
      ; avg_px : Price.t
      ; client_order_id : Client_order_id.t option
      }
  | Rejected of Reject_reason.t
[@@deriving sexp, compare, equal]
