open! Core

type t =
  { symbol : Symbol.t
  ; size : Size.t
  ; entry_px : Price.t
  ; notional : Usd.t
  ; unrealized_pnl : Usd.t
  ; realized_pnl : Usd.t
  ; cum_funding : Usd.t
  ; liquidation_px : Price.t option
  ; leverage : int
  ; max_leverage : int
  ; margin_used : Usd.t
  }
[@@deriving sexp, compare, equal]
