open! Core

type t =
  { account : Account.t
  ; balance : Usd.t
  ; equity : Usd.t
  ; total_notional : Usd.t
  ; margin_used : Usd.t
  ; maintenance_margin : Usd.t
  ; available : Usd.t
  ; positions : Position_view.t list
  ; time : int
  }
[@@deriving sexp, compare, equal]

let find_position t symbol =
  List.find t.positions ~f:(fun (p : Position_view.t) -> Symbol.equal p.symbol symbol)
;;
