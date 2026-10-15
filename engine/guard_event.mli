(** Audit records of the price collar and the halt rule, kept apart from {!Event.t} so
    that front ends matching every engine event are not affected
    ({!Exchange.drain_guard_events}).

    A collar or halt rejection also produces the ordinary [Order_rejected] event, with
    reason [Invalid_price] (collar) or [Unsupported "trading halted"] (halt); the guard
    event carries the reference and the bound. [before_seq] places a guard event in the
    engine's event log as for {!Trigger_event.t}: it happened after every
    {!Event.Numbered.t} numbered below [before_seq] and before the others.

    Guard events are derived from the inputs, so a journal replay reproduces them. *)

open! Core
open! Exchange_core

module Kind : sig
  type t =
    | Collar_rejected of
        { side : Side.t
        ; limit_px : Price.t
        (** the order's limit, or a market order's protection price *)
        ; reference : Price.t
        ; bound : Price.t
        }
    | Collar_repriced of
        { side : Side.t
        ; limit_px : Price.t
        ; repriced_px : Price.t
        ; reference : Price.t
        }
    (** written after matching, only when the collar changed the outcome: the order
        stopped at [repriced_px] with opposite liquidity left within [limit_px] *)
    | Halt_rejected of { side : Side.t } (** an order that would trade during a halt *)
    | Halted of
        { trigger_symbol : Symbol.t
        ; level : int (** index into [Halt_rule.Config.levels] *)
        ; reference : Price.t (** session reference of [trigger_symbol] *)
        ; px : Price.t (** the price that moved *)
        ; move_bps : int
        ; until : int option (** [None]: until {!Exchange.reopen} *)
        }
    | Reopen_pending (** the halt elapsed; waiting for {!Exchange.reopen} *)
    | Reopened
  [@@deriving sexp_of, compare, equal]
end

type t =
  { symbol : Symbol.t
  ; account : Account.t option (** the order's account, for collar and halt rejections *)
  ; order_id : Order_id.t option
  ; kind : Kind.t
  ; time : int
  ; before_seq : int
  }
[@@deriving sexp_of, compare, equal]

(** Counters since the exchange was created. *)
module Stats : sig
  type t =
    { collar_rejected : int
    ; collar_repriced : int
    ; collar_unreferenced : int
    (** orders that met a collar whose reference price was missing (passed unchecked) *)
    ; halt_rejected : int
    ; halts : int (** [Halted] events, one per halted symbol *)
    ; reopens : int
    }
  [@@deriving sexp_of, compare, equal]

  val zero : t
end
