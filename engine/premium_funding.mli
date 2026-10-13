(** Funding from the premium of the book over the oracle price (Hyperliquid docs,
    "Funding"):

    - every [sample_interval] the premium is sampled as
      [(max (impact_bid - oracle) 0 - max (oracle - impact_ask) 0) / oracle], where the
      impact prices are the average prices of selling and buying [impact_notional] against
      the book;
    - the 8-hour rate is [P + clamp (interest_rate - P) (-premium_clamp) premium_clamp],
      [P] the average of the interval's samples;
    - each funding interval pays its share of the 8-hour rate (one eighth for hourly
      funding), capped at [max_rate_per_hour] per hour either way. *)

open! Core
open! Exchange_core

module Config : sig
  type t =
    { interest_rate : float (** per 8 hours: 0.0001 *)
    ; premium_clamp : float (** 0.0005 *)
    ; max_rate_per_hour : float (** 0.04 *)
    ; sample_interval : Time_ns.Span.t (** 5 s *)
    ; impact_notional : (Symbol.t * Usd.t) list (** BTC and ETH: 20,000 *)
    ; default_impact_notional : Usd.t (** 6,000 *)
    }
  [@@deriving sexp_of]

  (** Hyperliquid's values. *)
  val default : t

  val impact_notional : t -> Symbol.t -> Usd.t
end

(** [(impact_bid, impact_ask)]: the average price of selling and of buying [notional] (or
    as much of it as the side holds) against levels given best first as [(px, size)];
    [None] for an empty side. *)
val impact_pxs
  :  bids:(Price.t * Size.t) list
  -> asks:(Price.t * Size.t) list
  -> notional:Usd.t
  -> float option * float option

(** The premium of the impact prices over [oracle]; a missing side counts as no premium on
    that side. *)
val premium : oracle:float -> impact_bid:float option -> impact_ask:float option -> float

(** The rate charged for one funding interval of [interval] given the average premium. *)
val rate : Config.t -> average_premium:float -> interval:Time_ns.Span.t -> float
