open! Core

module T = struct
  type t = int [@@deriving sexp, compare, equal, hash]
end

include T
include Comparable.Make (T)
include Hashable.Make (T)

let of_int = Fn.id
let to_int = Fn.id
let to_string = Int.to_string
