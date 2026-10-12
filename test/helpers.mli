open! Core
open! Exchange_core

(** [acct n] is the account [0x00...0n]. *)
val acct : int -> Account.t

val px : string -> Price.t
val sz : string -> Size.t
val usd : string -> Usd.t
val btc : Symbol.t
