open! Core

type t =
  | Unknown_symbol
  | Unsupported of string
  | Invalid_size
  | Invalid_price
  | Duplicate_client_order_id
  | Reduce_only_would_increase
  | Below_min_value of { min : Usd.t }
  | Insufficient_margin
  | No_liquidity
  | Self_trade
  | Post_only_would_cross of
      { best_bid : Price.t option
      ; best_ask : Price.t option
      }
  | Order_not_found
[@@deriving sexp, compare, equal]
