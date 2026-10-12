(** Client-assigned order id. Opaque to the engine; venues validate their own format. *)

open! Core

type t [@@deriving sexp, compare, equal, hash]

include Comparable.S with type t := t
include Hashable.S with type t := t
include Stringable.S with type t := t
