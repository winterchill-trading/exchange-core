(** Why an order was rejected. Venues render these in their own wording. *)

open! Core

type t =
  | Unknown_symbol
  | Unsupported of string (** an order kind the venue adapter does not support *)
  | Invalid_size (** not positive or not a multiple of the lot size *)
  | Invalid_price (** not positive, off tick, too many significant figures, or missing *)
  | Duplicate_client_order_id (** the account already has a resting order with this id *)
  | Reduce_only_would_increase (** reduce-only order with nothing to reduce *)
  | Below_min_value of { min : Usd.t } (** notional below the minimum *)
  | Insufficient_margin
  | No_liquidity (** IOC or market order with nothing to match against *)
  | Self_trade (** the first maker in priority belongs to the same account *)
  | Post_only_would_cross of
      { best_bid : Price.t option
      ; best_ask : Price.t option
      }
  | Order_not_found (** modify target is not a resting order of the account *)
[@@deriving sexp, compare, equal]
