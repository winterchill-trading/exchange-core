(** Synthetic background order flow, so the simulated book is alive without external
    traders.

    Each instrument has a reference price following a geometric random walk. On every tick
    the walk advances, the exchange's mark is set to the reference price, and each of [N]
    noise trader accounts may, per instrument:
    - cancel its oldest resting order (always when it has more than
      [max_orders_per_symbol]);
    - post a GTC limit order a random distance from the reference price, bids below and
      asks above it (resting orders left behind by the walk cross and trade);
    - post a GTC limit order strictly inside the spread
      ([Config.inside_touch_probability]);
    - send a small market order.

    All randomness comes from a [Random.State.t] seeded with [Config.seed], and the
    simulator never reads the clock, so [tick] sequences are reproducible. Driving [tick]
    on a timer is the front end's job. *)

open! Core
open! Exchange_core

module Config : sig
  type t =
    { seed : int
    ; symbols : Symbol.t list (** instruments to trade; empty means all of them *)
    ; initial_prices : (Symbol.t * Price.t) list
    (** starting reference prices by symbol; unlisted symbols start at [default_price] *)
    ; vol_bps : float (** standard deviation of the reference price over 1s, in bps *)
    ; noise_traders : int
    ; trader_balance : Usd.t (** deposited into each noise trader at creation *)
    ; tick_interval : Time_ns.Span.t
    ; max_orders_per_symbol : int (** per trader *)
    ; post_probability : float (** per trader, instrument and tick *)
    ; cancel_probability : float
    ; market_probability : float
    ; inside_touch_probability : float
    (** per trader, instrument and tick: post a GTC order strictly inside the spread when
        it is wider than one tick. At [0.] no random number is drawn for it, so runs match
        those of configurations without this field. *)
    ; max_offset_bps : float (** limit orders rest up to this far from the reference *)
    ; min_notional : float
    (** USD size range of an order. Per instrument, both bounds are scaled up by the same
        factor when one lot at the price is worth more than [min_notional], and a size
        never rounds below one lot. *)
    ; max_notional : float
    }
  [@@deriving sexp_of]

  (** A plausible starting price, recognising the base asset by prefix (case insensitive):
      BTC 100000, ETH 3500, SOL 150, anything else 100. ["BTC"], ["BTCUSDT"] and
      ["BTC-PERP"] all get the BTC price. *)
  val default_price : Symbol.t -> Price.t

  (** [default_price] for each symbol, for [initial_prices]. *)
  val default_prices : Symbol.t list -> (Symbol.t * Price.t) list

  (** Seed 0, all instruments, [default_prices] of {!Exchange.Config.default_instruments},
      5 bps/s, 10 traders with $10M each, 100ms ticks, up to 5 orders per instrument per
      trader, probabilities 0.3 / 0.1 / 0.02, offsets up to 25 bps, $20 to $2000 per
      order, no inside-touch orders. *)
  val default : t

  (** [default] with seed [seed] and the flow parameters drawn from a generator seeded by
      [seed]: volatility 1 to 20 bps/s, 3 to 15 traders, post / cancel / market / inside
      probabilities in [0.1, 0.5] / [0.05, 0.3] / [0.005, 0.05] / [0, 0.2], offsets up to
      5 to 50 bps. The same seed always gives the same configuration. *)
  val randomize : seed:int -> t
end

type t

(** Deposits [trader_balance] into every noise trader. *)
val create : Config.t -> Exchange.t -> t

val config : t -> Config.t

(** The noise trader accounts: ["0x"], 32 [f]s, then the trader index in 8 hex digits. *)
val traders : t -> Account.t list

(** The reference price rounded to a valid price of the instrument. *)
val reference_price : t -> Symbol.t -> Price.t option

(** Advances the walk one tick and generates that tick's orders. Does not move the
    exchange clock. *)
val tick : t -> unit
