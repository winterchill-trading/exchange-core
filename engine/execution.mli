(** One account's side of a fill, as kept in its fill history. *)

open! Core
open! Exchange_core

type t =
  { fill : Order_book.Fill.t
  ; settlement : Clearinghouse.Settlement.t
  }
[@@deriving sexp_of]

(** The account's order id: the taker's if [settlement.crossed], else the maker's. *)
val order_id : t -> Order_id.t

val client_order_id : t -> Client_order_id.t option
