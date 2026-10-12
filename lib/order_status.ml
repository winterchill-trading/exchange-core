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
