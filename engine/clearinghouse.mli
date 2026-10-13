(** Accounts, positions and cross margin for all users.

    Margin model (cross margin only, one-way positions):
    - equity = balance + unrealised PnL at mark over all positions;
    - initial margin of a position = [|size| * mark / leverage], where leverage is the
      account's per-instrument setting (default [min default_leverage max_leverage]);
    - maintenance margin = [|size| * mark / (2 * max_leverage)];
    - an account whose equity falls below its maintenance margin is liquidated by closing
      all of its positions at mark (no liquidator, no backstop vault).

    Fees come from each instrument's {!Exchange_core.Fee_schedule}. Marks are supplied by
    the caller as a lookup; when an instrument has no mark the position's entry price is
    used. *)

open! Core
open! Exchange_core

type t [@@deriving sexp_of]

(** [default_leverage] (default 20) is capped by each instrument's [max_leverage]. *)
val create : ?default_leverage:int -> Instrument.t list -> t

val instruments : t -> Instrument.t list

(** Raises for symbols not in the universe. *)
val instrument : t -> Symbol.t -> Instrument.t

(** Total fees charged so far. *)
val fees_collected : t -> Usd.t

(** The account, created with a zero balance if new. *)
val account : t -> Account.t -> Account_state.t

val find_account : t -> Account.t -> Account_state.t option

(** All accounts, sorted by account id. *)
val accounts : t -> Account_state.t list

(** Credits (or debits, if negative) the account's balance. *)
val deposit : t -> Account.t -> Usd.t -> unit

(** Raises for symbols not in the universe. *)
val max_leverage : t -> Symbol.t -> int

val leverage : t -> Account.t -> Symbol.t -> int

(** Sets cross leverage; fails unless [1 <= leverage <= max_leverage]. *)
val set_leverage : t -> Account.t -> Symbol.t -> int -> unit Or_error.t

type mark = Symbol.t -> Price.t option

val balance : t -> Account.t -> Usd.t

(** Balance plus unrealised PnL. *)
val equity : t -> Account.t -> mark:mark -> Usd.t

(** Initial margin used by positions. *)
val margin_used : t -> Account.t -> mark:mark -> Usd.t

val maintenance_margin : t -> Account.t -> mark:mark -> Usd.t

(** Initial margin an order of [sz] at [px] would need: only the part that increases the
    position's absolute size is charged. *)
val order_margin
  :  t
  -> Account.t
  -> symbol:Symbol.t
  -> side:Side.t
  -> px:Price.t
  -> sz:Size.t
  -> Usd.t

(** Checks that [equity - margin used - reserved] covers [order_margin]. [reserved] is the
    margin held by the account's other resting orders. *)
val check_order_margin
  :  t
  -> Account.t
  -> symbol:Symbol.t
  -> side:Side.t
  -> px:Price.t
  -> sz:Size.t
  -> reserved:Usd.t
  -> mark:mark
  -> unit Or_error.t

(** The largest size on [side] that only reduces the current position (zero if flat or if
    [side] would increase it). *)
val reduce_only_size : t -> Account.t -> symbol:Symbol.t -> side:Side.t -> Size.t

module Settlement : sig
  (** One side of a settled fill. *)
  type t =
    { account : Account.t
    ; side : Side.t
    ; crossed : bool (** taker *)
    ; fee : Usd.t
    ; change : Position.Change.t
    }
  [@@deriving sexp_of, compare, equal]
end

(** Applies a fill to both accounts: updates positions, realises PnL into balances and
    charges fees. Returns [(taker, maker)]. *)
val settle_fill : t -> Order_book.Fill.t -> Settlement.t * Settlement.t

(** [settle_fill] returning an unboxed pair, for callers that would only take the tuple
    apart. *)
val settle_fill_u : t -> Order_book.Fill.t -> #(Settlement.t * Settlement.t)

module Liquidation : sig
  type t =
    { account : Account.t
    ; symbol : Symbol.t
    ; size : Size.t (** position closed *)
    ; px : Price.t
    ; pnl : Usd.t
    }
  [@@deriving sexp_of, compare, equal]
end

(** Liquidates every account whose equity is below its maintenance margin by closing all
    its positions at mark. Returns one entry per closed position. *)
val mark_to_market : t -> mark:mark -> Liquidation.t list

(** The accounts whose equity is below their maintenance margin, in account order, without
    liquidating them (for a front end that liquidates through the book). Like
    [mark_to_market], forgets accounts that have gone flat. *)
val below_maintenance : t -> mark:mark -> Account.t list

(** Backstop liquidation: moves every position of [from] to [to_] at mark (realising
    [from]'s PnL, [to_] taking the same positions at mark), then the whole remaining
    balance of [from], so [from] is left flat with nothing. Returns one entry per position
    moved, as [mark_to_market] does for closed ones. *)
val transfer_positions
  :  t
  -> from:Account.t
  -> to_:Account.t
  -> mark:mark
  -> Liquidation.t list

module Funding_payment : sig
  type t =
    { account : Account.t
    ; symbol : Symbol.t
    ; size : Size.t
    ; payment : Usd.t (** paid by the account if positive, received if negative *)
    }
  [@@deriving sexp_of, compare, equal]
end

(** Charges every position in [symbol] [size * mark * rate]: with a positive rate longs
    pay and shorts receive. Zero-sum whenever open interest is balanced. *)
val apply_funding
  :  t
  -> symbol:Symbol.t
  -> rate:float
  -> mark:Price.t
  -> Funding_payment.t list

(** The account summary at mark. [time] is passed through. *)
val view : t -> Account.t -> mark:mark -> time:int -> Account_view.t
