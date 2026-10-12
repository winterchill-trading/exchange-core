open! Core

type t =
  | Gtc
  | Ioc
  | Alo
[@@deriving sexp, compare, equal, hash, enumerate]
