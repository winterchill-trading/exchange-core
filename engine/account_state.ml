open! Core
open! Exchange_core

type t =
  { account : Account.t
  ; mutable balance : Usd.t
  ; positions : Position.t Symbol.Table.t
  ; leverage : int Symbol.Table.t
  ; mutable position_list : Position.t list [@sexp_drop_if Fn.const true]
  }
[@@deriving sexp_of]

let create account =
  { account
  ; balance = Usd.zero
  ; positions = Symbol.Table.create ()
  ; leverage = Symbol.Table.create ()
  ; position_list = []
  }
;;

let add_balance t usd = t.balance <- Usd.( + ) t.balance usd

let position t symbol =
  match Hashtbl.find t.positions symbol with
  | Some p when not (Position.is_flat p) -> Some p
  | _ -> None
;;

let position_or_create t symbol =
  match Hashtbl.find t.positions symbol with
  | Some p -> p
  | None ->
    let p = Position.create symbol in
    Hashtbl.set t.positions ~key:symbol ~data:p;
    t.position_list <- p :: t.position_list;
    p
;;

let rec any_open = function
  | [] -> false
  | p :: rest -> (not (Position.is_flat p)) || any_open rest
;;

let has_open_position t = any_open t.position_list

let open_positions t =
  Hashtbl.data t.positions
  |> List.filter ~f:(fun p -> not (Position.is_flat p))
  |> List.sort ~compare:(fun (a : Position.t) b -> Symbol.compare a.symbol b.symbol)
;;

let set_leverage t symbol lev = Hashtbl.set t.leverage ~key:symbol ~data:lev
let leverage t symbol = Hashtbl.find t.leverage symbol
