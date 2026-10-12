open! Core
open! Exchange_core

module Cancel_reason = struct
  type t =
    | User
    | Modified
    | Ioc_unfilled
    | Self_trade
    | Liquidated
  [@@deriving sexp_of, compare, equal]
end

type t =
  | Order_accepted of
      { account : Account.t
      ; order : Open_order.t
      ; time : int
      }
  | Order_rejected of
      { account : Account.t
      ; symbol : Symbol.t option
      ; order_id : Order_id.t option
      ; client_order_id : Client_order_id.t option
      ; reason : Reject_reason.t
      ; time : int
      }
  | Fill of
      { fill : Order_book.Fill.t
      ; taker : Clearinghouse.Settlement.t
      ; maker : Clearinghouse.Settlement.t
      }
  | Order_filled of
      { account : Account.t
      ; order : Open_order.t
      ; time : int
      }
  | Order_cancelled of
      { account : Account.t
      ; order : Open_order.t
      ; reason : Cancel_reason.t
      ; time : int
      }
  | Liquidation of
      { liquidation : Clearinghouse.Liquidation.t
      ; time : int
      }
  | Funding of
      { symbol : Symbol.t
      ; rate : float
      ; mark : Price.t
      ; payments : Clearinghouse.Funding_payment.t list
      ; time : int
      }
[@@deriving sexp_of]

let time = function
  | Order_accepted { time; _ }
  | Order_rejected { time; _ }
  | Order_filled { time; _ }
  | Order_cancelled { time; _ }
  | Liquidation { time; _ }
  | Funding { time; _ } -> time
  | Fill { fill; _ } -> fill.time
;;

let book_symbol = function
  | Order_accepted { order; _ } | Order_cancelled { order; _ } -> Some order.symbol
  | Fill { fill; _ } -> Some fill.symbol
  | Order_rejected _ | Order_filled _ | Liquidation _ | Funding _ -> None
;;

let executions = function
  | Fill { fill; taker; maker } ->
    Some ({ Execution.fill; settlement = taker }, { Execution.fill; settlement = maker })
  | _ -> None
;;

module Numbered = struct
  type event = t [@@deriving sexp_of]

  type t =
    { seq : int
    ; event : event
    }
  [@@deriving sexp_of]
end
