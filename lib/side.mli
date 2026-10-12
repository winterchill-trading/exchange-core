(** Order or trade side. *)

open! Core

type t =
  | Buy
  | Sell
[@@deriving sexp, compare, equal, hash, enumerate]

val of_is_buy : bool -> t
val is_buy : t -> bool
val flip : t -> t

(** [sign Buy = 1], [sign Sell = -1]. *)
val sign : t -> int
