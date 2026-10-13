(** Hyperliquid's robust prices for one instrument: an oracle price published from outside
    the book, and a mark price derived from it and the book (Hyperliquid docs, "Robust
    price indices").

    The mark is the median of
    + the oracle plus a 150 s exponential moving average of [mid - oracle];
    + the median of the best bid, best ask and last trade price;
    + a weighted median of other venues' perp mids, which a simulator does not have.

    When exactly two of these exist, a 30 s moving average of the second is added as a
    third input. Averages are updated at each oracle update with the time since the
    previous one, as [ema = numerator / denominator] where
    [numerator <- numerator * exp(-t / tau) + sample * t] and
    [denominator <- denominator * exp(-t / tau) + t]. Prices are handled as floats; the
    caller rounds the mark to a valid price. *)

open! Core

module Ema : sig
  type t [@@deriving sexp_of]

  (** An empty average with time constant [tau]. *)
  val create : tau:Time_ns.Span.t -> t

  (** Adds [sample], weighted by the [dt] since the previous update. *)
  val update : t -> sample:float -> dt:Time_ns.Span.t -> unit

  (** [None] until it has a sample; the latest sample while all weights are zero. *)
  val value : t -> float option
end

type t [@@deriving sexp_of]

val create : unit -> t

(** The last published oracle price, if any. *)
val oracle : t -> float option

(** Publishes an oracle price at [now] (nanoseconds) and returns the new mark. [mid] is
    the book mid, [best_bid], [best_ask] and [last_trade] the book's other prices, each
    [None] when absent. With no book input at all, the mark is the oracle. *)
val update
  :  t
  -> now:int
  -> oracle:float
  -> mid:float option
  -> best_bid:float option
  -> best_ask:float option
  -> last_trade:float option
  -> float

(** The median of a list (the mean of the two middle values for an even length); [None]
    for an empty list. *)
val median : float list -> float option
