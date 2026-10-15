(** A market-wide (or per-symbol) circuit breaker: when a watched symbol's price moves
    more than a level's threshold away from its session reference, trading halts for the
    level's duration.

    The levels work like the market-wide circuit breakers of equity markets: each level
    triggers at most once per session, a move that reaches several untriggered levels at
    once triggers the highest, and the last level usually halts for the rest of the
    session. The rule is venue-neutral; the TradFi simulators keep their own per-stock
    limit-up/limit-down bands.

    While a symbol is halted, orders that would trade on entry (market orders and limit
    orders crossing the book) are rejected; passive orders rest and cancels work, so the
    book can be rebuilt for the reopening. With [Reopen.On_request] the halt lasts until
    the front end calls {!Exchange.reopen}, typically after running a reopening auction of
    its own. *)

open! Core
open! Exchange_core

module Level : sig
  type t =
    { move_bps : int (** absolute move from the session reference that triggers it *)
    ; duration_ns : int option (** [None]: halted until {!Exchange.reopen} *)
    }
  [@@deriving sexp, compare, equal]
end

module Scope : sig
  type t =
    | Market_wide (** a trigger in any watched symbol halts every instrument *)
    | Per_symbol (** a trigger halts only the symbol that moved *)
  [@@deriving sexp, compare, equal]
end

module Reopen : sig
  type t =
    | Automatic (** trading resumes when the duration has elapsed (at a [step]) *)
    | On_request
    (** when the duration has elapsed the symbol waits, with a [Reopen_pending] guard
        event, until {!Exchange.reopen}: the hook for a reopening auction *)
  [@@deriving sexp, compare, equal]
end

module Config : sig
  type t =
    { levels : Level.t list (** ascending [move_bps] *)
    ; scope : Scope.t
    ; watch : Symbol.t list (** symbols whose moves trigger a halt; empty for every one *)
    ; observe : Price_collar.Reference.t (** which price is compared *)
    ; reopen : Reopen.t
    }
  [@@deriving sexp, compare, equal]

  (** 7%, 13% for 15 minutes each, 20% for the rest of the session; market wide, every
      symbol watched, on the mark, automatic reopening. *)
  val default : t

  (** An error unless levels are non-empty, strictly ascending and positive, and durations
      positive. *)
  val validate : t -> unit Or_error.t
end

(** Absolute move of [px] from [reference] in basis points, rounded down. *)
val move_bps : reference:Price.t -> px:Price.t -> int

(** The index of the level to trigger, given that levels [0 .. triggered - 1] have
    triggered this session: the highest untriggered level the move reaches. *)
val level_to_trigger
  :  Config.t
  -> triggered:int
  -> reference:Price.t
  -> px:Price.t
  -> int option

val watches : Config.t -> Symbol.t -> bool
