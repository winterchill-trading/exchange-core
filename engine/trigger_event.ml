open! Core
open! Exchange_core

module Kind = struct
  type t =
    | Placed
    | Triggered
    | Cancelled of Event.Cancel_reason.t
  [@@deriving sexp_of, compare, equal]
end

type t =
  { order : Trigger_order.t
  ; kind : Kind.t
  ; time : int
  ; before_seq : int
  }
[@@deriving sexp_of]
