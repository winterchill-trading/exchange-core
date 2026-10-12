(** Exchange-assigned order id. *)

open! Core

type t [@@deriving sexp, compare, equal, hash]

include Comparable.S with type t := t
include Hashable.S with type t := t

val of_int64 : int64 -> t
val to_int64 : t -> int64
val of_int : int -> t
val to_int_exn : t -> int
val to_string : t -> string
val of_string : string -> t
