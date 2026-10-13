open! Core
open! Exchange_core
open! Exchange_core_engine

let n_accounts = 1_000
let n_resting = 100
let btc = Symbol.of_string "BTC"
let addr n = Account.of_string (sprintf "0x%040x" n)
let maker = addr 0
let taker = addr (n_accounts + 1)
let quoter = addr (n_accounts + 2)
let n_quoter_orders = 500
let best_bid = 49_999
let best_ask = 50_001
let px n = Price.of_int n
let deep = Size.of_int 10_000
let min_size = Size.of_string "0.001"
let trade_size = Size.of_string "0.01"

let place_exn ex account req =
  match (Exchange.place ex account req : Order_status.t) with
  | Rejected reason -> raise_s [%message "Scenario: rejected" (reason : Reject_reason.t)]
  | Resting _ | Filled _ -> ()
;;

let limit ?(tif = Tif.Gtc) side p size = Order_request.limit ~tif btc side ~px:p ~size

let create () =
  let ex = Exchange.create () in
  Exchange.deposit ex maker (Usd.of_int 10_000_000_000);
  Exchange.set_mark ex btc (px 50_000);
  for i = 0 to (n_resting / 2) - 1 do
    let size = if i = 0 then deep else Size.of_int 1 in
    place_exn ex maker (limit Buy (px (best_bid - i)) size);
    place_exn ex maker (limit Sell (px (best_ask + i)) size)
  done;
  for i = 1 to n_accounts do
    let account = addr i in
    Exchange.deposit ex account (Usd.of_int 100_000);
    let side, p = if i % 2 = 0 then Side.Buy, best_ask else Sell, best_bid in
    place_exn ex account (limit ~tif:Ioc side (px p) trade_size)
  done;
  Exchange.deposit ex taker (Usd.of_int 100_000);
  ignore (Exchange.drain_events ex : Event.t list);
  ex
;;

let create_quoter () =
  let ex = Exchange.create () in
  Exchange.set_mark ex btc (px 50_000);
  Exchange.deposit ex quoter (Usd.of_int 10_000_000);
  for i = 1 to n_quoter_orders do
    let offset = Price.of_string (sprintf "%d.%d" (i / 10) (i % 10)) in
    place_exn ex quoter (limit Buy (Price.( - ) (px 45_000) offset) min_size)
  done;
  ignore (Exchange.drain_events ex : Event.t list);
  ex
;;

let step ex () = Exchange.step ex ~now:(Exchange.now ex + 1)

let match_round_trip ex () =
  place_exn ex taker (limit ~tif:Ioc Buy (px best_ask) min_size);
  place_exn ex taker (limit ~tif:Ioc Sell (px best_bid) min_size);
  ignore (Exchange.drain_events ex : Event.t list)
;;

let place_and_cancel_as account ex () =
  match
    Exchange.place_with_order_id ex account (limit Buy (px (best_bid - 1_000)) min_size)
  with
  | oid, Resting _ ->
    ignore (Exchange.cancel ex account ~symbol:btc oid : Cancel_status.t);
    ignore (Exchange.drain_events ex : Event.t list)
  | _, status -> raise_s [%message "Scenario: not resting" (status : Order_status.t)]
;;

let place_and_cancel = place_and_cancel_as taker
let maker_place_and_cancel = place_and_cancel_as maker
let quoter_place_and_cancel = place_and_cancel_as quoter
