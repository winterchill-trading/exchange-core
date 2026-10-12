(** Rebuilds order books from an exchange's event stream alone, the way a venue front end
    or a market-data consumer would: [Order_accepted] adds a resting order, [Fill] reduces
    or removes the maker, [Order_cancelled] removes a resting order. Other events do not
    change books.

    Events must be applied in sequence order without gaps, starting at the sequence number
    given to {!create}; anything else is an error, as is an event that does not fit the
    rebuilt book (a fill of an unknown maker, an accepted order that would cross). A
    cancel of an order that is not on the book is ignored: IOC and market remainders are
    cancelled without ever resting. *)

open! Core
open! Exchange_core

type t

(** Empty books for [symbols]. [next_seq] defaults to 1, the first event of an exchange. *)
val create : ?next_seq:int -> Symbol.t list -> t

(** Sequence number of the next expected event. *)
val next_seq : t -> int

val apply : t -> Event.Numbered.t -> unit Or_error.t
(** Stops at the first error. *)
val apply_all : t -> Event.Numbered.t list -> unit Or_error.t
val book : t -> Symbol.t -> Order_book.t option

(** Aggregated snapshot of a rebuilt book, in the same shape as {!Exchange.l2}. *)
val l2 : t -> Symbol.t -> n_levels:int -> time:int -> L2.t option
