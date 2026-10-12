(** Instrument name, e.g. ["BTC"] or ["BTCUSDT"]. The engine treats it as opaque. *)

open! Core

type t [@@deriving sexp, compare, equal, hash]

include Comparable.S with type t := t
include Hashable.S with type t := t
include Stringable.S with type t := t
