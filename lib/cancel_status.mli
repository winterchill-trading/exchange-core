(** Outcome of a cancel request. *)

open! Core

type t =
  | Cancelled
  | Not_found (** never placed, already cancelled or filled, or not the account's *)
[@@deriving sexp, compare, equal]
