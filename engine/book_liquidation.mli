(** Liquidation through the order book, as on Hyperliquid (docs, "Liquidations"), instead
    of closing positions at the mark ({!Exchange.create}'s [book_liquidation]).

    An account whose equity is below its maintenance margin first has its resting and
    trigger orders cancelled. Then:
    - if its equity is still at least [backstop_fraction] of the maintenance margin, every
      position gets a reduce-only market order to the book from the account itself: for
      the whole position, or for [partial_fraction] of it when its notional is above
      [partial_above] and the account has not been partially liquidated within the last
      [cooldown]. Whatever the book cannot absorb stays open;
    - otherwise the backstop takes over: the positions and the remaining balance move to
      the [liquidator] account at the mark, leaving the account with nothing.

    This runs wherever the engine liquidates (after [set_mark], [set_oracle] and [step]),
    so a position the book did not close is looked at again on the next mark. *)

open! Core
open! Exchange_core

module Config : sig
  type t =
    { liquidator : Account.t (** takes over backstop liquidations *)
    ; partial_above : Usd.t (** Hyperliquid: 100,000 USDC (10,000 on testnet) *)
    ; partial_fraction : float (** 0.2 *)
    ; cooldown : Time_ns.Span.t (** 30 s *)
    ; backstop_fraction : float (** 2/3 *)
    }
  [@@deriving sexp_of, equal]

  (** Hyperliquid's mainnet values with the given liquidator. *)
  val create : liquidator:Account.t -> t
end

module Method : sig
  type t =
    | Market (** a market order to the book *)
    | Backstop (** taken over by the liquidator *)
  [@@deriving sexp_of, compare, equal]
end

(** One liquidation step of one position, kept apart from {!Event.t} (as
    {!Trigger_event.t} is) and ordered against it by [before_seq]. For [Market], the
    order's own events and fills follow under [order_id]. *)
module Event : sig
  type t =
    { account : Account.t
    ; symbol : Symbol.t
    ; method_ : Method.t
    ; order_id : Order_id.t option (** the market order, for [Market] *)
    ; size : Size.t (** signed position size before the step *)
    ; order_size : Size.t (** sent to the book, or taken over *)
    ; mark : Price.t
    ; equity : Usd.t (** of the account when it was liquidated *)
    ; notional : Usd.t (** of the account's positions at mark *)
    ; time : int
    ; before_seq : int
    }
  [@@deriving sexp_of]
end
