(** How an order executes. *)

open! Core

type t =
  | Limit of Tif.t (** at the request's limit price *)
  | Market of { slippage_bps : int option }
  (** an IOC order priced [slippage_bps] through the best opposite price ([None]: the
      engine's default) *)
[@@deriving sexp, compare, equal]

val gtc : t
val ioc : t
val alo : t
val market : t
