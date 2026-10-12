(** A resting order as reported to its owner, also used in order lifecycle events. *)

open! Core

type t =
  { symbol : Symbol.t
  ; side : Side.t
  ; px : Price.t
  ; size : Size.t (** remaining size *)
  ; orig_size : Size.t option
  ; order_id : Order_id.t
  ; client_order_id : Client_order_id.t option
  ; timestamp : int (** nanoseconds at which the order was accepted *)
  }
[@@deriving sexp, compare, equal]
