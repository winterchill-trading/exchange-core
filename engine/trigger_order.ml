open! Core
open! Exchange_core

type t =
  { account : Account.t
  ; order_id : Order_id.t
  ; request : Order_request.t
  ; trigger : Trigger.t
  ; timestamp : int
  }
[@@deriving sexp_of, compare, equal]

let open_order t : Open_order.t =
  { symbol = t.request.symbol
  ; side = t.request.side
  ; px = Option.value t.request.px ~default:t.trigger.trigger_px
  ; size = t.request.size
  ; orig_size = Some t.request.size
  ; order_id = t.order_id
  ; client_order_id = t.request.client_order_id
  ; timestamp = t.timestamp
  }
;;
