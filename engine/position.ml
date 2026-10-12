open! Core
open! Exchange_core
module Notional = Fixed_decimal.Product (Price) (Size) (Usd)

type t =
  { symbol : Symbol.t
  ; mutable size : Size.t
  ; mutable entry_px : Price.t
  ; mutable realized_pnl : Usd.t
  ; mutable cum_funding : Usd.t
  }
[@@deriving sexp_of]

let create symbol =
  { symbol
  ; size = Size.zero
  ; entry_px = Price.zero
  ; realized_pnl = Usd.zero
  ; cum_funding = Usd.zero
  }
;;

let is_flat t = Size.is_zero t.size

module Direction = struct
  type t =
    | Open_long
    | Open_short
    | Close_long
    | Close_short
    | Long_to_short
    | Short_to_long
  [@@deriving sexp, compare, equal, hash, enumerate]
end

module Change = struct
  type t =
    { start_position : Size.t
    ; closed_pnl : Usd.t
    ; direction : Direction.t
    }
  [@@deriving sexp_of, compare, equal]
end

(* PnL of closing [closed] (signed like the position) opened at [entry] at [px]. *)
let pnl ~entry ~px ~closed =
  Usd.( - ) (Notional.mul px closed) (Notional.mul entry closed)
;;

let signed (side : Side.t) sz =
  match side with
  | Buy -> sz
  | Sell -> Size.neg sz
;;

let apply_trade t ~side ~px ~sz : Change.t =
  let start = t.size in
  let delta = signed side sz in
  let next = Size.( + ) start delta in
  let same_direction =
    Size.is_zero start || Bool.equal (Size.is_positive start) (Size.is_positive delta)
  in
  let closed_pnl, (direction : Direction.t) =
    if same_direction
    then (
      (* Increase: weighted average entry. *)
      let notional =
        Usd.( + ) (Notional.mul t.entry_px (Size.abs start)) (Notional.mul px sz)
      in
      t.entry_px <- Notional.div notional (Size.abs next);
      Usd.zero, if Size.is_positive delta then Open_long else Open_short)
    else (
      let closed =
        if Size.( <= ) (Size.abs delta) (Size.abs start) then Size.neg delta else start
      in
      let realized = pnl ~entry:t.entry_px ~px ~closed in
      let flipped =
        (not (Size.is_zero next))
        && not (Bool.equal (Size.is_positive next) (Size.is_positive start))
      in
      if flipped then t.entry_px <- px;
      let direction : Direction.t =
        match Size.is_positive start, flipped with
        | true, false -> Close_long
        | false, false -> Close_short
        | true, true -> Long_to_short
        | false, true -> Short_to_long
      in
      realized, direction)
  in
  t.size <- next;
  if Size.is_zero next then t.entry_px <- Price.zero;
  t.realized_pnl <- Usd.( + ) t.realized_pnl closed_pnl;
  { start_position = start; closed_pnl; direction }
;;

let notional t ~mark = Notional.mul mark t.size
let unrealized_pnl t ~mark = pnl ~entry:t.entry_px ~px:mark ~closed:t.size

let close_at t ~px =
  let realized = unrealized_pnl t ~mark:px in
  t.realized_pnl <- Usd.( + ) t.realized_pnl realized;
  t.size <- Size.zero;
  t.entry_px <- Price.zero;
  realized
;;

let add_funding t payment = t.cum_funding <- Usd.( + ) t.cum_funding payment
