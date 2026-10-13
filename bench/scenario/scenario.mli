(** The exchange the step and submit benches run against, shared with the allocation
    tests: [n_accounts] traders each holding a small BTC position, and one maker with
    [n_resting] resting orders (half bids, half asks) whose best levels are deep enough
    that a small taker never empties them. *)

open! Core
open! Exchange_core
open! Exchange_core_engine

val n_accounts : int
val n_resting : int
val btc : Symbol.t
val maker : Account.t
val taker : Account.t
val create : unit -> Exchange.t

(** Advances the clock by one nanosecond: no funding, every account marked. *)
val step : Exchange.t -> unit -> unit

(** An IOC buy and an IOC sell of the minimum size against the best levels (two fills, the
    book shape is unchanged), then drains the events. *)
val match_round_trip : Exchange.t -> unit -> unit

(** A passive bid below the book that rests, then its cancel, then drains the events. *)
val place_and_cancel : Exchange.t -> unit -> unit

(** The same for the maker, whose margin check walks its [n_resting] resting orders. *)
val maker_place_and_cancel : Exchange.t -> unit -> unit

val n_quoter_orders : int

(** A separate exchange where one account quotes [n_quoter_orders] resting bids. *)
val create_quoter : unit -> Exchange.t

(** [place_and_cancel] for that account, on an exchange from [create_quoter]. *)
val quoter_place_and_cancel : Exchange.t -> unit -> unit
