open! Core
open! Exchange_core

type t =
  | Order_id of Order_id.t
  | Client_order_id of Client_order_id.t
[@@deriving sexp, compare, equal]
