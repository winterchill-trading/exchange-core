(** One position of an account, valued at mark. *)

open! Core

type t =
  { symbol : Symbol.t
  ; size : Size.t (** signed: positive long, negative short *)
  ; entry_px : Price.t (** volume-weighted average entry price *)
  ; notional : Usd.t (** [|size| * mark] *)
  ; unrealized_pnl : Usd.t
  ; realized_pnl : Usd.t (** cumulative closed PnL, before fees and funding *)
  ; cum_funding : Usd.t (** cumulative funding paid (positive) or received *)
  ; liquidation_px : Price.t option
  (** estimated mark at which the account would be liquidated, other marks fixed *)
  ; leverage : int
  ; max_leverage : int
  ; margin_used : Usd.t (** initial margin: [notional / leverage] *)
  }
[@@deriving sexp, compare, equal]
