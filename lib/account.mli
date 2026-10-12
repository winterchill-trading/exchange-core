(** Account identifier: an address, an API key id or a user name; opaque to the engine. *)

open! Core

type t [@@deriving sexp, compare, equal, hash]

include Comparable.S with type t := t
include Hashable.S with type t := t
include Stringable.S with type t := t
