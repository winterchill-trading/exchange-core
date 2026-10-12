open! Core

module T = struct
  type t = Int64.t [@@deriving sexp, compare, equal, hash]
end

include T
include Comparable.Make (T)
include Hashable.Make (T)

let of_int64 = Fn.id
let to_int64 = Fn.id
let of_int = Int64.of_int
let to_int_exn = Int64.to_int_exn
let to_string = Int64.to_string
let of_string = Int64.of_string
