open! Core

type t =
  { symbol : Symbol.t
  ; side : Side.t
  ; px : Price.t
  ; size : Size.t
  ; orig_size : Size.t option
  ; order_id : Order_id.t
  ; client_order_id : Client_order_id.t option
  ; timestamp : int
  }
[@@deriving sexp, compare, equal]
