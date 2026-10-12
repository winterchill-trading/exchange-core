open! Core
open! Exchange_core

type t =
  { fill : Order_book.Fill.t
  ; settlement : Clearinghouse.Settlement.t
  }
[@@deriving sexp_of]

let order_id t = if t.settlement.crossed then t.fill.taker_oid else t.fill.maker_oid

let client_order_id t =
  if t.settlement.crossed then t.fill.taker_cloid else t.fill.maker_cloid
;;
