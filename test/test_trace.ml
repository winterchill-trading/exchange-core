open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

(* One line per book level and per account after every step, so a change in matching,
   margin or funding shows up as a readable diff. *)

let maker = acct 1
let taker = acct 2
let accounts = [ "maker", maker; "taker", taker ]

let print_book ex =
  let l2 = Option.value_exn (Exchange.l2 ex btc ~n_levels:3) in
  let side name (levels : L2.Level.t list) =
    List.map levels ~f:(fun l ->
      sprintf "%s@%s(%d)" (Size.to_string l.sz) (Price.to_string l.px) l.n)
    |> String.concat ~sep:" "
    |> printf "  %s %s\n" name
  in
  side "asks" (List.rev l2.asks);
  side "bids" l2.bids;
  printf
    "  mark %s\n"
    (Option.value_map (Exchange.mark ex btc) ~default:"-" ~f:Price.to_string)
;;

let print_account ex (name, account) =
  let v = Exchange.account_view ex account in
  let u = Usd.to_string in
  printf
    "  %-5s bal %s eq %s im %s mm %s avail %s"
    name
    (u v.balance)
    (u v.equity)
    (u v.margin_used)
    (u v.maintenance_margin)
    (u v.available);
  List.iter v.positions ~f:(fun p ->
    printf
      " | %s %s@%s upnl %s fund %s"
      (Symbol.to_string p.symbol)
      (Size.to_string p.size)
      (Price.to_string p.entry_px)
      (u p.unrealized_pnl)
      (u p.cum_funding));
  print_endline ""
;;

let print_events ex =
  List.iter (Exchange.drain_numbered_events ex) ~f:(fun { seq; event } ->
    let s =
      match event with
      | Order_accepted { order; _ } ->
        sprintf
          "accepted #%s %s %s@%s"
          (Order_id.to_string order.order_id)
          (Side.sexp_of_t order.side |> Sexp.to_string)
          (Size.to_string order.size)
          (Price.to_string order.px)
      | Order_rejected { reason; _ } ->
        "rejected " ^ Sexp.to_string [%sexp (reason : Reject_reason.t)]
      | Fill { fill; _ } ->
        sprintf
          "fill %s@%s taker #%s maker #%s"
          (Size.to_string fill.sz)
          (Price.to_string fill.px)
          (Order_id.to_string fill.taker_oid)
          (Order_id.to_string fill.maker_oid)
      | Order_filled { order; _ } ->
        sprintf "filled #%s" (Order_id.to_string order.order_id)
      | Order_cancelled { order; reason; _ } ->
        sprintf
          "cancelled #%s %s"
          (Order_id.to_string order.order_id)
          (Sexp.to_string [%sexp (reason : Event.Cancel_reason.t)])
      | Liquidation { liquidation = l; _ } ->
        sprintf
          "liquidated %s@%s pnl %s"
          (Size.to_string l.size)
          (Price.to_string l.px)
          (Usd.to_string l.pnl)
      | Funding { rate; mark; payments; _ } ->
        sprintf
          "funding rate %g mark %s payments %d"
          rate
          (Price.to_string mark)
          (List.length payments)
    in
    printf "  %3d %s\n" seq s)
;;

let step ex label f =
  f ();
  printf "== %s (t=%ds)\n" label (Exchange.now ex / 1_000_000_000);
  print_events ex;
  print_book ex;
  List.iter accounts ~f:(print_account ex)
;;

let limit side p s = Order_request.limit btc side ~px:(px p) ~size:(sz s)
let place ex who req = ignore (Exchange.place ex who req : Order_status.t)

let%expect_test "scripted trace: quote, take, mark move, funding, liquidation" =
  let ex = Exchange.create () in
  step ex "deposits" (fun () ->
    Exchange.deposit ex maker (usd "100000");
    Exchange.deposit ex taker (usd "1000"));
  step ex "maker quotes two levels a side" (fun () ->
    place ex maker (limit Buy "99900" "0.1");
    place ex maker (limit Buy "99800" "0.2");
    place ex maker (limit Sell "100100" "0.1");
    place ex maker (limit Sell "100200" "0.2"));
  step ex "taker lifts the offer through the first level" (fun () ->
    ignore (Exchange.set_leverage ex taker btc 40 : unit Or_error.t);
    place ex taker (Order_request.market btc Buy ~size:(sz "0.15")));
  step ex "mark rises" (fun () -> Exchange.set_mark ex btc (px "100500"));
  step ex "one hour: funding" (fun () -> Exchange.step ex ~now:(3_600 * 1_000_000_000));
  step ex "mark drops: taker is liquidated" (fun () ->
    Exchange.set_mark ex btc (px "93000"));
  [%expect
    {|
    == deposits (t=0s)
      asks
      bids
      mark -
      maker bal 100000 eq 100000 im 0 mm 0 avail 100000
      taker bal 1000 eq 1000 im 0 mm 0 avail 1000
    == maker quotes two levels a side (t=0s)
        1 accepted #1 Buy 0.1@99900
        2 accepted #2 Buy 0.2@99800
        3 accepted #3 Sell 0.1@100100
        4 accepted #4 Sell 0.2@100200
      asks 0.2@100200(1) 0.1@100100(1)
      bids 0.1@99900(1) 0.2@99800(1)
      mark 100000
      maker bal 100000 eq 100000 im 0 mm 0 avail 100000
      taker bal 1000 eq 1000 im 0 mm 0 avail 1000
    == taker lifts the offer through the first level (t=0s)
        5 fill 0.1@100100 taker #5 maker #3
        6 filled #3
        7 fill 0.05@100200 taker #5 maker #4
        8 filled #5
      asks 0.15@100200(1)
      bids 0.1@99900(1) 0.2@99800(1)
      mark 100200
      maker bal 99998.498 eq 99988.49799999 im 751.5 mm 187.875 avail 99236.99799999 | BTC -0.15@100133.33333333 upnl -10.00000001 fund 0
      taker bal 994.743 eq 1004.74300001 im 375.75 mm 187.875 avail 628.99300001 | BTC 0.15@100133.33333333 upnl 10.00000001 fund 0
    == mark rises (t=0s)
      asks 0.15@100200(1)
      bids 0.1@99900(1) 0.2@99800(1)
      mark 100500
      maker bal 99998.498 eq 99943.49799999 im 753.75 mm 188.4375 avail 99189.74799999 | BTC -0.15@100133.33333333 upnl -55.00000001 fund 0
      taker bal 994.743 eq 1049.74300001 im 376.875 mm 188.4375 avail 672.86800001 | BTC 0.15@100133.33333333 upnl 55.00000001 fund 0
    == one hour: funding (t=3600s)
        9 funding rate 1.25e-05 mark 100500 payments 2
      asks 0.15@100200(1)
      bids 0.1@99900(1) 0.2@99800(1)
      mark 100500
      maker bal 99998.6864375 eq 99943.68643749 im 753.75 mm 188.4375 avail 99189.93643749 | BTC -0.15@100133.33333333 upnl -55.00000001 fund -0.1884375
      taker bal 994.5545625 eq 1049.55456251 im 376.875 mm 188.4375 avail 672.67956251 | BTC 0.15@100133.33333333 upnl 55.00000001 fund 0.1884375
    == mark drops: taker is liquidated (t=3600s)
       10 liquidated 0.15@93000 pnl -1069.99999999
      asks 0.15@100200(1)
      bids 0.1@99900(1) 0.2@99800(1)
      mark 93000
      maker bal 99998.6864375 eq 101068.68643749 im 697.5 mm 174.375 avail 100371.18643749 | BTC -0.15@100133.33333333 upnl 1069.99999999 fund -0.1884375
      taker bal -75.44543749 eq -75.44543749 im 0 mm 0 avail 0
    |}]
;;
