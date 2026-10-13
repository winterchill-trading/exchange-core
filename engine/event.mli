(** Everything that happens on the exchange, in order. Venue front ends stream these
    (public trades, order updates, user fills, book updates after book-changing events).
    All [time] fields are nanoseconds from the exchange clock. *)

open! Core
open! Exchange_core

module Cancel_reason : sig
  type t =
    | User (** cancel request *)
    | Modified (** replaced by a modify request *)
    | Ioc_unfilled (** IOC or market remainder *)
    | Self_trade
    (** removed by self-trade prevention: a taker's remainder, or an own resting order
        expired by the taker ([Expire_maker], [Cancel_both]) *)
    | Liquidated (** the account was liquidated *)
  [@@deriving sexp_of, compare, equal]
end

type t =
  | Order_accepted of
      { account : Account.t
      ; order : Open_order.t (** rests on the book with [size] remaining *)
      ; time : int
      }
  | Order_rejected of
      { account : Account.t
      ; symbol : Symbol.t option
      ; order_id : Order_id.t option
      (** the id {!Exchange.place} assigned; [None] for rejections recorded by a front end
          without one, and for a modify whose target was not found *)
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
      (** [size] is zero; for a maker filled by someone else's order [px] is the last fill
          price, [orig_size] is [None] and [timestamp] the fill time *)
      ; time : int
      }
  | Order_cancelled of
      { account : Account.t
      ; order : Open_order.t (** [size] is the size that was cancelled *)
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

val time : t -> int

(** The instrument whose book changed, if any. *)
val book_symbol : t -> Symbol.t option

(** The two executions of a [Fill] event, [(taker, maker)]. *)
val executions : t -> (Execution.t * Execution.t) option

(** An event with its position in the exchange's event log. *)
module Numbered : sig
  type event := t

  type t =
    { seq : int (** 1 for the first event of an exchange, then consecutive *)
    ; event : event
    }
  [@@deriving sexp_of]
end
