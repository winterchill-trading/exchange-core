(** The whole simulated exchange: one order book per instrument, the clearinghouse, mark
    prices, id counters, a caller-driven clock and an event log.

    Time is an [int] count of nanoseconds supplied by the caller ([step]); the exchange
    never reads the wall clock, so runs are deterministic. Every request and response uses
    the venue-neutral types of {!Exchange_core}; venue front ends translate them. *)

open! Core
open! Exchange_core

module Config : sig
  type t =
    { instruments : Instrument.t list
    ; default_leverage : int (** capped by each instrument's [max_leverage] *)
    ; funding_interval_ns : int (** funding is charged at each multiple of this *)
    ; default_funding_rate : float (** per interval, until [set_funding_rate] *)
    ; min_order_value : Usd.t (** reduce-only orders are exempt *)
    ; market_slippage_bps : int (** default for market orders *)
    ; l2_levels : int (** default depth of [l2] *)
    }
  [@@deriving sexp_of]

  (** BTC (size decimals 5, tick 0.1, 40x), ETH (4, 0.01, 25x), SOL (2, 0.0001, 20x),
      default fees. *)
  val default_instruments : Instrument.t list

  (** [default_instruments], 20x, hourly funding at 0.00125%, $10 minimum, 5% market
      slippage, 20 levels. *)
  val default : t
end

type t

val create : ?config:Config.t -> unit -> t
val config : t -> Config.t
val instruments : t -> Instrument.t list
val instrument : t -> Symbol.t -> Instrument.t option
val clearinghouse : t -> Clearinghouse.t

(** Current time in nanoseconds. *)
val now : t -> int

(** {2 Accounts} *)

val deposit : t -> Account.t -> Usd.t -> unit
val set_leverage : t -> Account.t -> Symbol.t -> int -> unit Or_error.t

(** {2 Orders} *)

(** Validates, margin-checks and matches an order. Checks, in order: known symbol, price
    (limit orders), size, duplicate client order id, reduce-only (a reduce-only order is
    clipped to the size that reduces the position), minimum value, margin. A market order
    is an IOC order priced [slippage_bps] through the best opposite price. *)
val place : t -> Account.t -> Order_request.t -> Order_status.t

(** Records a rejection decided by a venue front end (e.g. an unsupported order kind), so
    that it appears in the event log like the engine's own rejections. Returns
    [Rejected reason]. *)
val reject
  :  ?symbol:Symbol.t
  -> ?client_order_id:Client_order_id.t
  -> t
  -> Account.t
  -> Reject_reason.t
  -> Order_status.t

(** Cancels a resting order of the account in [symbol]. *)
val cancel : t -> Account.t -> symbol:Symbol.t -> Order_id.t -> Cancel_status.t

val cancel_by_client_order_id
  :  t
  -> Account.t
  -> symbol:Symbol.t
  -> Client_order_id.t
  -> Cancel_status.t

module Target : sig
  type t =
    | Order_id of Order_id.t
    | Client_order_id of Client_order_id.t
  [@@deriving sexp, compare, equal]
end

(** Cancels the target order (in any symbol) and places the replacement with a new order
    id, losing time priority. If the target is not a resting order of the account the
    result is [Rejected Order_not_found]; if the replacement is rejected the original
    stays cancelled. *)
val modify : t -> Account.t -> Target.t -> Order_request.t -> Order_status.t

(** {2 Views} *)

val l2 : ?n_levels:int -> t -> Symbol.t -> L2.t option

(** Book mids, in universe order; instruments without a two-sided book are omitted. *)
val mids : t -> (Symbol.t * Price.t) list

(** Resting orders, newest first. *)
val open_orders : t -> Account.t -> Open_order.t list

(** Executions, newest first. *)
val fills : t -> Account.t -> Execution.t list

val account_view : t -> Account.t -> Account_view.t

(** {2 Prices, funding and time} *)

(** Mark price: the last [set_mark], else the last trade price, else the book mid. *)
val mark : t -> Symbol.t -> Price.t option

(** Sets the mark price and liquidates accounts that fall below maintenance margin. *)
val set_mark : t -> Symbol.t -> Price.t -> unit

val set_funding_rate : t -> Symbol.t -> float -> unit

(** The funding rate per interval charged at the next funding boundary: the last
    [set_funding_rate] for the symbol, else [Config.default_funding_rate]. *)
val funding_rate : t -> Symbol.t -> float

(** Advances the clock to [now] (raises if it would go backwards), charges funding for
    every funding boundary crossed, then liquidates under-margined accounts. *)
val step : t -> now:int -> unit

(** {2 Events} *)

(** Returns the events since the previous call, oldest first, and forgets them. *)
val drain_events : t -> Event.t list

(** The order book of an instrument, for inspection. *)
val book : t -> Symbol.t -> Order_book.t option
