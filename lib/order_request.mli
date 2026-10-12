(** A new order. *)

open! Core

type t =
  { symbol : Symbol.t
  ; side : Side.t
  ; size : Size.t
  ; px : Price.t option (** limit price, required by [Limit] and ignored by [Market] *)
  ; order_type : Order_type.t
  ; reduce_only : bool
  ; client_order_id : Client_order_id.t option
  }
[@@deriving sexp, compare, equal]

val limit
  :  ?tif:Tif.t (** default [Gtc] *)
  -> ?reduce_only:bool
  -> ?client_order_id:Client_order_id.t
  -> Symbol.t
  -> Side.t
  -> px:Price.t
  -> size:Size.t
  -> t

val market
  :  ?slippage_bps:int
  -> ?reduce_only:bool
  -> ?client_order_id:Client_order_id.t
  -> Symbol.t
  -> Side.t
  -> size:Size.t
  -> t
