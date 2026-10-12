(** Time in force of a limit order. *)

open! Core

type t =
  | Gtc (** good til cancelled: any remainder rests on the book *)
  | Ioc (** immediate or cancel: any remainder is cancelled *)
  | Alo
  (** add liquidity only (post only): rejected if it would match on arrival, otherwise
      rests in full *)
[@@deriving sexp, compare, equal, hash, enumerate]
