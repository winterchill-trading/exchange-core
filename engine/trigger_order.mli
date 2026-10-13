(** A trigger order waiting off the book for the mark price ({!Exchange.place_trigger}).
    When it fires, [request] is placed as an ordinary order under the same [order_id]. *)

open! Core
open! Exchange_core

type t =
  { account : Account.t
  ; order_id : Order_id.t
  ; request : Order_request.t
  ; trigger : Trigger.t
  ; timestamp : int (** nanoseconds at which it was accepted *)
  }
[@@deriving sexp_of, compare, equal]

(** The order as its owner sees it: the request's limit price, or [trigger_px] for a
    market request. *)
val open_order : t -> Open_order.t
