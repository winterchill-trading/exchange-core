open! Core

module T = struct
  type t = string [@@deriving sexp, compare, equal, hash]

  let of_string = Fn.id
  let to_string = Fn.id
end

include T
include Comparable.Make (T)
include Hashable.Make (T)
