open! Core

module Kind = struct
  type t =
    | Take_profit
    | Stop_loss
  [@@deriving sexp, compare, equal, hash, enumerate]
end

type t =
  { trigger_px : Price.t
  ; kind : Kind.t
  }
[@@deriving sexp, compare, equal]

let fires_above t ~(side : Side.t) =
  match side, t.kind with
  | Buy, Stop_loss | Sell, Take_profit -> true
  | Sell, Stop_loss | Buy, Take_profit -> false
;;

let fires t ~side ~mark =
  if fires_above t ~side
  then Price.( >= ) mark t.trigger_px
  else Price.( <= ) mark t.trigger_px
;;
