(** A cross-margin trading account: a balance plus one position per instrument. The
    balance already includes realised PnL, fees and funding; equity adds unrealised PnL at
    mark (see {!Clearinghouse}). *)

open! Core
open! Exchange_core

type t = private
  { account : Account.t
  ; mutable balance : Usd.t
  ; positions : Position.t Symbol.Table.t
  ; leverage : int Symbol.Table.t (** per-instrument leverage overrides *)
  }
[@@deriving sexp_of]

val create : Account.t -> t
val add_balance : t -> Usd.t -> unit

(** The position in [symbol], if not flat. *)
val position : t -> Symbol.t -> Position.t option

(** The position record in [symbol], created flat if absent. *)
val position_or_create : t -> Symbol.t -> Position.t

(** Non-flat positions, sorted by symbol. *)
val open_positions : t -> Position.t list

val set_leverage : t -> Symbol.t -> int -> unit
val leverage : t -> Symbol.t -> int option
