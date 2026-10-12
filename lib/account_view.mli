(** Cross-margin summary of one account, valued at mark. *)

open! Core

type t =
  { account : Account.t
  ; balance : Usd.t (** deposits plus realised PnL, minus fees and funding *)
  ; equity : Usd.t (** balance plus unrealised PnL *)
  ; total_notional : Usd.t (** sum of [|size| * mark] over positions *)
  ; margin_used : Usd.t (** initial margin of positions *)
  ; maintenance_margin : Usd.t
  ; available : Usd.t (** [max 0 (equity - margin_used)] *)
  ; positions : Position_view.t list (** sorted by symbol *)
  ; time : int (** nanoseconds, from the exchange clock *)
  }
[@@deriving sexp, compare, equal]

val find_position : t -> Symbol.t -> Position_view.t option
