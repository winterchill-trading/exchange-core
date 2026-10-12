open! Core

type t =
  | Buy
  | Sell
[@@deriving sexp, compare, equal, hash, enumerate]

let of_is_buy is_buy = if is_buy then Buy else Sell

let is_buy = function
  | Buy -> true
  | Sell -> false
;;

let flip = function
  | Buy -> Sell
  | Sell -> Buy
;;

let sign = function
  | Buy -> 1
  | Sell -> -1
;;
