(** What happens to trigger orders, kept apart from {!Event.t} so that front ends matching
    every engine event are not affected by trigger orders they do not offer
    ({!Exchange.drain_trigger_events}).

    [before_seq] places a trigger event in the engine's event log: it happened after every
    {!Event.Numbered.t} numbered below [before_seq] and before the others. A fired order's
    own events (accepted, filled, rejected, ...) follow its [Triggered] event. *)

open! Core
open! Exchange_core

module Kind : sig
  type t =
    | Placed (** waiting for the mark *)
    | Triggered (** the mark reached the trigger price; the order is being placed *)
    | Cancelled of Event.Cancel_reason.t (** removed before it fired *)
  [@@deriving sexp_of, compare, equal]
end

type t =
  { order : Trigger_order.t
  ; kind : Kind.t
  ; time : int
  ; before_seq : int
  }
[@@deriving sexp_of]
