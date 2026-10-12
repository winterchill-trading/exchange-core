open! Core

type t =
  { symbol : Symbol.t
  ; side : Side.t
  ; size : Size.t
  ; px : Price.t option
  ; order_type : Order_type.t
  ; reduce_only : bool
  ; client_order_id : Client_order_id.t option
  }
[@@deriving sexp, compare, equal]

let limit ?(tif = Tif.Gtc) ?(reduce_only = false) ?client_order_id symbol side ~px ~size =
  { symbol
  ; side
  ; size
  ; px = Some px
  ; order_type = Limit tif
  ; reduce_only
  ; client_order_id
  }
;;

let market ?slippage_bps ?(reduce_only = false) ?client_order_id symbol side ~size =
  { symbol
  ; side
  ; size
  ; px = None
  ; order_type = Market { slippage_bps }
  ; reduce_only
  ; client_order_id
  }
;;
