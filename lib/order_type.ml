open! Core

type t =
  | Limit of Tif.t
  | Market of { slippage_bps : int option }
[@@deriving sexp, compare, equal]

let gtc = Limit Gtc
let ioc = Limit Ioc
let alo = Limit Alo
let market = Market { slippage_bps = None }
