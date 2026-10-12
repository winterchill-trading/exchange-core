(** Every request that changes the state of an {!Exchange.t}, as a value.

    An exchange reports each of its mutating calls to its input recorders (see
    {!Exchange.record_inputs}), and {!Exchange.apply} performs one. Applying the recorded
    inputs, in order, to a fresh exchange with the same configuration reproduces the
    original run exactly, events included, because the engine is deterministic.

    The binary encoding ([bin_prot]) does not depend on the in-memory representation of
    the fixed-point and id types: prices, sizes and amounts are written as their integer
    units, ids and names as strings or integers. *)

open! Core
open! Exchange_core

type t =
  | Deposit of
      { account : Account.t
      ; usd : Usd.t
      }
  | Set_leverage of
      { account : Account.t
      ; symbol : Symbol.t
      ; leverage : int
      }
  | Place of
      { account : Account.t
      ; request : Order_request.t
      }
  | Reject of
      { account : Account.t
      ; symbol : Symbol.t option
      ; order_id : Order_id.t option
      ; client_order_id : Client_order_id.t option
      ; reason : Reject_reason.t
      }
  | Cancel of
      { account : Account.t
      ; symbol : Symbol.t
      ; order_id : Order_id.t
      }
  | Cancel_by_client_order_id of
      { account : Account.t
      ; symbol : Symbol.t
      ; client_order_id : Client_order_id.t
      }
  | Modify of
      { account : Account.t
      ; target : Target.t
      ; request : Order_request.t
      }
  | Set_mark of
      { symbol : Symbol.t
      ; px : Price.t
      }
  | Set_funding_rate of
      { symbol : Symbol.t
      ; rate : float
      }
  | Step of { now : int }
[@@deriving sexp_of, compare, equal]

include Binable.S with type t := t
