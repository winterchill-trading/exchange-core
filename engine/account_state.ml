open! Core
open! Exchange_core

type t =
  { account : Account.t
  ; mutable balance : Usd.t
  ; positions : Position.t Symbol.Table.t
  ; leverage : int Symbol.Table.t
  }
[@@deriving sexp_of]

let create account =
  { account
  ; balance = Usd.zero
  ; positions = Symbol.Table.create ()
  ; leverage = Symbol.Table.create ()
  }
;;

let add_balance t usd = t.balance <- Usd.( + ) t.balance usd

let position t symbol =
  match Hashtbl.find t.positions symbol with
  | Some p when not (Position.is_flat p) -> Some p
  | _ -> None
;;

let position_or_create t symbol =
  Hashtbl.find_or_add t.positions symbol ~default:(fun () -> Position.create symbol)
;;

let open_positions t =
  Hashtbl.data t.positions
  |> List.filter ~f:(fun p -> not (Position.is_flat p))
  |> List.sort ~compare:(fun (a : Position.t) b -> Symbol.compare a.symbol b.symbol)
;;

let set_leverage t symbol lev = Hashtbl.set t.leverage ~key:symbol ~data:lev
let leverage t symbol = Hashtbl.find t.leverage symbol
