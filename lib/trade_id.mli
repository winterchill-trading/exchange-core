(** Exchange-assigned trade (fill) id, unique across the exchange. *)

open! Core

type t [@@deriving sexp, compare, equal, hash]

include Comparable.S with type t := t
include Hashable.S with type t := t

val of_int : int -> t
val to_int : t -> int
val to_string : t -> string
