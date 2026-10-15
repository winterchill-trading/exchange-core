open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

let maker = acct 1
let taker = acct 2
let other = acct 3

(* Asks at 1000, 1004, 1010 and bids at 999, 996, 990, one unit each. *)
let fresh ?(collar : Price_collar.Config.t option) () =
  let ex = Exchange.create () in
  List.iter [ maker; taker; other ] ~f:(fun a -> Exchange.deposit ex a (usd "1000000"));
  List.iter [ "1000"; "1004"; "1010" ] ~f:(fun p ->
    ignore
      (Exchange.place ex maker (Order_request.limit btc Sell ~px:(px p) ~size:(sz "1"))
       : Order_status.t));
  List.iter [ "999"; "996"; "990" ] ~f:(fun p ->
    ignore
      (Exchange.place ex maker (Order_request.limit btc Buy ~px:(px p) ~size:(sz "1"))
       : Order_status.t));
  Exchange.set_mark ex btc (px "1000");
  Option.iter collar ~f:(fun c -> ok_exn (Exchange.set_collar ex btc (Some c)));
  ignore (Exchange.drain_events ex : Event.t list);
  ex
;;

let show ex (status : Order_status.t) =
  print_s [%sexp (status : Order_status.t)];
  List.iter (Exchange.drain_events ex) ~f:(function
    | Fill { fill; _ } -> printf !"  fill %{Size}@%{Price}\n" fill.sz fill.px
    | Order_accepted { order; _ } ->
      printf !"  rests %{Size}@%{Price}\n" order.size order.px
    | Order_rejected { reason; _ } ->
      printf !"  rejected %{sexp: Reject_reason.t}\n" reason
    | Order_cancelled { order; reason; _ } ->
      printf !"  cancelled %{Size} %{sexp: Event.Cancel_reason.t}\n" order.size reason
    | Order_filled _ | Liquidation _ | Funding _ -> ());
  List.iter (Exchange.drain_guard_events ex) ~f:(fun (g : Guard_event.t) ->
    print_s [%sexp "guard", (g.kind : Guard_event.Kind.t)])
;;

let buy ?(tif = Tif.Gtc) ex p s =
  show
    ex
    (Exchange.place ex taker (Order_request.limit ~tif btc Buy ~px:(px p) ~size:(sz s)))
;;

let sell ?(tif = Tif.Gtc) ?(who = taker) ex p s =
  show
    ex
    (Exchange.place ex who (Order_request.limit ~tif btc Sell ~px:(px p) ~size:(sz s)))
;;

let market ex side s =
  show ex (Exchange.place ex taker (Order_request.market btc side ~size:(sz s)))
;;

let bps ?(reference = Price_collar.Reference.Mark) action n : Price_collar.Config.t =
  { reference; band = Bps n; action }
;;

let%expect_test "without a collar a buy sweeps the book" =
  let ex = fresh () in
  buy ex "1010" "3";
  [%expect
    {|
    (Filled (order_id 7) (total 3) (avg_px 1004.66666666) (client_order_id ()))
      fill 1@1000
      fill 1@1004
      fill 1@1010
    |}]
;;

let%expect_test "reject: a marketable order priced beyond the band" =
  let ex = fresh ~collar:(bps Reject 50) () in
  (* Mark 1000, band 0.5%: buys up to 1005, sells down to 995. *)
  buy ex "1010" "3";
  sell ex "990" "3";
  (* Within the band it trades as usual. *)
  buy ex "1005" "3";
  (* Beyond the band but not marketable: it rests (nothing to collar). *)
  sell ex "1020" "1";
  print_s [%sexp (Exchange.guard_stats ex : Guard_event.Stats.t)];
  [%expect
    {|
    (Rejected Invalid_price)
      rejected Invalid_price
    (guard
     (Collar_rejected (side Buy) (limit_px 1010) (reference 1000) (bound 1005)))
    (Rejected Invalid_price)
      rejected Invalid_price
    (guard
     (Collar_rejected (side Sell) (limit_px 990) (reference 1000) (bound 995)))
    (Resting (order_id 9) (client_order_id ()))
      fill 1@1000
      fill 1@1004
      rests 1@1005
    (Resting (order_id 10) (client_order_id ()))
      rests 1@1020
    ((collar_rejected 2) (collar_repriced 0) (collar_unreferenced 0)
     (halt_rejected 0) (halts 0) (reopens 0))
    |}]
;;

let%expect_test "reprice: the limit moves to the band" =
  let ex = fresh ~collar:(bps Reprice 50) () in
  buy ex "1010" "3";
  (* IOC from another account (the taker now has a bid at 1005): the remainder is
     cancelled. *)
  sell ~tif:Ioc ~who:other ex "980" "4";
  [%expect
    {|
    (Resting (order_id 7) (client_order_id ()))
      fill 1@1000
      fill 1@1004
      rests 1@1005
    (guard
     (Collar_repriced (side Buy) (limit_px 1010) (repriced_px 1005)
      (reference 1000)))
    (Filled (order_id 8) (total 3) (avg_px 1000) (client_order_id ()))
      fill 1@1005
      fill 1@999
      fill 1@996
      cancelled 1 Ioc_unfilled
    (guard
     (Collar_repriced (side Sell) (limit_px 980) (repriced_px 995)
      (reference 1000)))
    |}]
;;

let%expect_test "reprice that changes nothing is not audited" =
  let ex = fresh ~collar:(bps Reprice 50) () in
  (* Fully filled at 1000 within the band: no guard event. *)
  buy ex "1010" "1";
  [%expect
    {|
    (Filled (order_id 7) (total 1) (avg_px 1000) (client_order_id ()))
      fill 1@1000
    |}]
;;

let%expect_test "market orders are clamped to the band, even with Reject" =
  let ex = fresh ~collar:(bps Reject 50) () in
  market ex Buy "3";
  market ex Sell "3";
  [%expect
    {|
    (Filled (order_id 7) (total 2) (avg_px 1002) (client_order_id ()))
      fill 1@1000
      fill 1@1004
      cancelled 1 Ioc_unfilled
    (guard
     (Collar_repriced (side Buy) (limit_px 1050) (repriced_px 1005)
      (reference 1000)))
    (Filled (order_id 8) (total 2) (avg_px 997.5) (client_order_id ()))
      fill 1@999
      fill 1@996
      cancelled 1 Ioc_unfilled
    (guard
     (Collar_repriced (side Sell) (limit_px 949.05) (repriced_px 995)
      (reference 1000)))
    |}]
;;

let%expect_test "post-only orders are not checked" =
  let ex = fresh ~collar:(bps Reject 1) () in
  buy ~tif:Alo ex "1010" "1";
  buy ~tif:Alo ex "998" "1";
  [%expect
    {|
    (Rejected (Post_only_would_cross (best_bid (999)) (best_ask (1000))))
      rejected (Post_only_would_cross (best_bid (999)) (best_ask (1000)))
    (Resting (order_id 8) (client_order_id ()))
      rests 1@998
    |}]
;;

let%expect_test "ticks band on the last trade, and on the mid" =
  let ex =
    fresh ~collar:{ reference = Last_trade; band = Ticks 20; action = Reject } ()
  in
  (* No trade yet: the collar has no reference and lets the order through. *)
  buy ex "1004" "1";
  (* Last trade 1000 (then 1004): 20 ticks of 0.1 = 2, so 1006 is the limit. *)
  print_s [%sexp (Exchange.collar_reference ex btc : Price.t option)];
  buy ex "1010" "1";
  print_s [%sexp (Exchange.guard_stats ex : Guard_event.Stats.t)];
  ok_exn
    (Exchange.set_collar
       ex
       btc
       (Some { reference = Mid; band = Ticks 20; action = Reject }));
  print_s [%sexp (Exchange.collar_reference ex btc : Price.t option)];
  sell ex "990" "1";
  [%expect
    {|
    (Filled (order_id 7) (total 1) (avg_px 1000) (client_order_id ()))
      fill 1@1000
    (1000)
    (Rejected Invalid_price)
      rejected Invalid_price
    (guard
     (Collar_rejected (side Buy) (limit_px 1010) (reference 1000) (bound 1002)))
    ((collar_rejected 1) (collar_repriced 0) (collar_unreferenced 1)
     (halt_rejected 0) (halts 0) (reopens 0))
    (1001.5)
    (Rejected Invalid_price)
      rejected Invalid_price
    (guard
     (Collar_rejected (side Sell) (limit_px 990) (reference 1001.5)
      (bound 999.5)))
    |}]
;;

let%expect_test "an external reference fed through set_mark" =
  let ex = fresh ~collar:(bps Reject 50) () in
  (* The reference market moved: the book is stale at 1000, so buys there still trade
     (better for the aggressor) but sells are held at 1100 * 0.995. *)
  Exchange.set_mark ex btc (px "1100");
  ignore (Exchange.drain_events ex : Event.t list);
  buy ex "1010" "1";
  sell ex "999" "1";
  [%expect
    {|
    (Filled (order_id 7) (total 1) (avg_px 1000) (client_order_id ()))
      fill 1@1000
    (Rejected Invalid_price)
      rejected Invalid_price
    (guard
     (Collar_rejected (side Sell) (limit_px 999) (reference 1100) (bound 1094.5)))
    |}]
;;

let%expect_test "set_collar errors" =
  let ex = fresh () in
  print_s
    [%sexp
      (Exchange.set_collar ex (Symbol.of_string "XYZ") (Some (bps Reject 50))
       : unit Or_error.t)];
  print_s [%sexp (Exchange.set_collar ex btc (Some (bps Reject 0)) : unit Or_error.t)];
  print_s [%sexp (Exchange.collar ex btc : Price_collar.Config.t option)];
  [%expect
    {|
    (Error ("Unknown symbol" (symbol XYZ)))
    (Error
     ("Price_collar: band must be positive"
      (t ((reference Mark) (band (Bps 0)) (action Reject)))))
    ()
    |}]
;;

let%expect_test "a journal replay reproduces the guard events" =
  let ex = Exchange.create () in
  let inputs = Queue.create () in
  Exchange.record_inputs ex ~f:(Queue.enqueue inputs);
  List.iter [ maker; taker ] ~f:(fun a -> Exchange.deposit ex a (usd "1000000"));
  ok_exn (Exchange.set_collar ex btc (Some (bps Reprice 30)));
  ignore
    (Exchange.place ex maker (Order_request.limit btc Sell ~px:(px "1000") ~size:(sz "1"))
     : Order_status.t);
  ignore
    (Exchange.place ex maker (Order_request.limit btc Sell ~px:(px "1010") ~size:(sz "1"))
     : Order_status.t);
  Exchange.set_mark ex btc (px "1000");
  ignore
    (Exchange.place ex taker (Order_request.limit btc Buy ~px:(px "1020") ~size:(sz "2"))
     : Order_status.t);
  let original = Exchange.drain_guard_events ex in
  let replayed = Exchange.create () in
  Queue.iter inputs ~f:(Exchange.apply replayed);
  let again = Exchange.drain_guard_events replayed in
  print_s
    [%sexp
      (List.length original : int), (List.equal Guard_event.equal original again : bool)];
  print_s [%sexp (again : Guard_event.t list)];
  [%expect
    {|
    (1 true)
    (((symbol BTC) (account (0x0000000000000000000000000000000000000002))
      (order_id (3))
      (kind
       (Collar_repriced (side Buy) (limit_px 1020) (repriced_px 1003)
        (reference 1000)))
      (time 0) (before_seq 6)))
    |}]
;;
