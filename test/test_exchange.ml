open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

let cid n = Client_order_id.of_string (sprintf "c%d" n)

let order ?tif ?reduce_only ?cid side p s =
  Order_request.limit
    ?tif
    ?reduce_only
    ?client_order_id:cid
    btc
    side
    ~px:(px p)
    ~size:(sz s)
;;

let place ex n ?tif ?reduce_only ?cid side p s =
  print_s
    [%sexp
      (Exchange.place ex (acct n) (order ?tif ?reduce_only ?cid side p s)
       : Order_status.t)]
;;

let short_addr a = Account.to_string a |> Fn.flip String.drop_prefix 38

let side_char : Side.t -> string = function
  | Buy -> "B"
  | Sell -> "A"
;;

let fresh () =
  let ex = Exchange.create () in
  List.iter [ 1; 2; 3 ] ~f:(fun n -> Exchange.deposit ex (acct n) (usd "10000"));
  ex
;;

let dir (s : Clearinghouse.Settlement.t) =
  Sexp.to_string [%sexp (s.change.direction : Position.Direction.t)]
;;

let summarize (e : Event.t) =
  let o (order : Open_order.t) =
    sprintf
      "oid=%s %s %s@%s"
      (Order_id.to_string order.order_id)
      (side_char order.side)
      (Size.to_string order.size)
      (Price.to_string order.px)
  in
  match e with
  | Order_accepted { account; order; _ } ->
    sprintf "accepted %s %s" (short_addr account) (o order)
  | Order_rejected { account; reason; _ } ->
    sprintf
      "rejected %s %s"
      (short_addr account)
      (Sexp.to_string [%sexp (reason : Reject_reason.t)])
  | Order_filled { account; order; _ } ->
    sprintf "filled %s %s" (short_addr account) (o order)
  | Order_cancelled { account; order; reason; _ } ->
    sprintf
      "cancelled %s %s %s"
      (short_addr account)
      (o order)
      (Sexp.to_string [%sexp (reason : Event.Cancel_reason.t)])
  | Fill { fill; taker; maker } ->
    sprintf
      "fill tid=%s %s@%s taker=%s(%s fee %s) maker=%s(%s fee %s)"
      (Trade_id.to_string fill.tid)
      (Size.to_string fill.sz)
      (Price.to_string fill.px)
      (short_addr fill.taker)
      (dir taker)
      (Usd.to_string taker.fee)
      (short_addr fill.maker)
      (dir maker)
      (Usd.to_string maker.fee)
  | Liquidation { liquidation = l; _ } ->
    sprintf
      "liquidation %s %s %s@%s pnl %s"
      (short_addr l.account)
      (Symbol.to_string l.symbol)
      (Size.to_string l.size)
      (Price.to_string l.px)
      (Usd.to_string l.pnl)
  | Funding { symbol; rate; mark; payments; _ } ->
    sprintf
      "funding %s rate=%g mark=%s %s"
      (Symbol.to_string symbol)
      rate
      (Price.to_string mark)
      (List.map payments ~f:(fun p ->
         sprintf "%s:%s" (short_addr p.account) (Usd.to_string p.payment))
       |> String.concat ~sep:" ")
;;

let print_events ex =
  List.iter (Exchange.drain_events ex) ~f:(fun e -> print_endline (summarize e))
;;

let%expect_test "resting, crossing, and the info views" =
  let ex = fresh () in
  Exchange.step ex ~now:1_000_000_000;
  place ex 1 Sell "100000" "0.01" ~cid:(cid 1);
  place ex 1 Sell "100100" "0.02";
  place ex 2 Buy "100100" "0.015";
  [%expect
    {|
    (Resting (order_id 1) (client_order_id (c1)))
    (Resting (order_id 2) (client_order_id ()))
    (Filled (order_id 3) (total 0.015) (avg_px 100033.33333333)
     (client_order_id ()))
    |}];
  print_events ex;
  [%expect
    {|
    accepted 0001 oid=1 A 0.01@100000
    accepted 0001 oid=2 A 0.02@100100
    fill tid=1 0.01@100000 taker=0002(Open_long fee 0.35) maker=0001(Open_short fee 0.1)
    filled 0001 oid=1 A 0@100000
    fill tid=2 0.005@100100 taker=0002(Open_long fee 0.175175) maker=0001(Open_short fee 0.05005)
    filled 0002 oid=3 B 0@100100
    |}];
  print_s [%sexp (Exchange.open_orders ex (acct 1) : Open_order.t list)];
  print_s [%sexp (Exchange.fills ex (acct 2) : Execution.t list)];
  print_s [%sexp (Exchange.l2 ex btc : L2.t option)];
  print_s [%sexp (Exchange.mids ex : (Symbol.t * Price.t) list)];
  [%expect
    {|
    (((symbol BTC) (side Sell) (px 100100) (size 0.015) (orig_size (0.02))
      (order_id 2) (client_order_id ()) (timestamp 1000000000)))
    (((fill
       ((tid 2) (symbol BTC) (px 100100) (sz 0.005) (taker_side Buy)
        (taker_oid 3) (maker_oid 2)
        (taker 0x0000000000000000000000000000000000000002)
        (maker 0x0000000000000000000000000000000000000001) (taker_cloid ())
        (maker_cloid ()) (time 1000000000)))
      (settlement
       ((account 0x0000000000000000000000000000000000000002) (side Buy)
        (crossed true) (fee 0.175175)
        (change ((start_position 0.01) (closed_pnl 0) (direction Open_long))))))
     ((fill
       ((tid 1) (symbol BTC) (px 100000) (sz 0.01) (taker_side Buy) (taker_oid 3)
        (maker_oid 1) (taker 0x0000000000000000000000000000000000000002)
        (maker 0x0000000000000000000000000000000000000001) (taker_cloid ())
        (maker_cloid (c1)) (time 1000000000)))
      (settlement
       ((account 0x0000000000000000000000000000000000000002) (side Buy)
        (crossed true) (fee 0.35)
        (change ((start_position 0) (closed_pnl 0) (direction Open_long)))))))
    (((symbol BTC) (time 1000000000) (bids ())
      (asks (((px 100100) (sz 0.015) (n 1))))))
    ()
    |}];
  print_s [%sexp (Exchange.account_view ex (acct 2) : Account_view.t)];
  [%expect
    {|
    ((account 0x0000000000000000000000000000000000000002) (balance 9999.474825)
     (equity 10000.47482501) (total_notional 1501.5) (margin_used 75.075)
     (maintenance_margin 18.76875) (available 9925.39982501)
     (positions
      (((symbol BTC) (size 0.015) (entry_px 100033.33333333) (notional 1501.5)
        (unrealized_pnl 1.00000001) (realized_pnl 0) (cum_funding 0)
        (liquidation_px ()) (leverage 20) (max_leverage 40) (margin_used 75.075))))
     (time 1000000000))
    |}]
;;

let%expect_test "rejections" =
  let ex = fresh () in
  place ex 1 Buy "100000" "0.000001";
  place ex 1 Buy "100000.05" "0.01";
  place ex 1 Buy "1000.0001" "0.01";
  place ex 1 Buy "100000" "0.0001";
  place ex 1 Buy "100000" "3";
  place ex 1 ~tif:Ioc Buy "100000" "0.01";
  place ex 1 ~reduce_only:true Sell "100000" "0.01";
  place ex 1 Sell "100000" "0.01";
  place ex 2 ~tif:Alo Buy "100000" "0.01";
  place ex 1 ~cid:(cid 7) Sell "100001" "0.01";
  place ex 1 ~cid:(cid 7) Sell "100002" "0.01";
  print_s
    [%sexp
      (Exchange.place
         ex
         (acct 1)
         { (order Buy "1" "10") with symbol = Symbol.of_string "DOGE" }
       : Order_status.t)];
  print_s
    [%sexp
      (Exchange.place ex (acct 1) { (order Buy "1" "10") with px = None }
       : Order_status.t)];
  print_s
    [%sexp (Exchange.reject ex (acct 1) (Unsupported "trigger orders") : Order_status.t)];
  [%expect
    {|
    (Rejected Invalid_size)
    (Rejected Invalid_price)
    (Rejected Invalid_price)
    (Resting (order_id 1) (client_order_id ()))
    (Rejected Insufficient_margin)
    (Rejected No_liquidity)
    (Rejected Reduce_only_would_increase)
    (Rejected Self_trade)
    (Resting (order_id 4) (client_order_id ()))
    (Resting (order_id 5) (client_order_id (c7)))
    (Rejected Duplicate_client_order_id)
    (Rejected Unknown_symbol)
    (Rejected Invalid_price)
    (Rejected (Unsupported "trigger orders"))
    |}]
;;

let%expect_test "self-trade, IOC partial fill and market orders" =
  let ex = fresh () in
  place ex 1 Sell "100000" "0.01";
  place ex 2 Sell "100100" "0.01";
  place ex 1 Buy "100200" "0.02";
  [%expect
    {|
    (Resting (order_id 1) (client_order_id ()))
    (Resting (order_id 2) (client_order_id ()))
    (Rejected Self_trade)
    |}];
  place ex 3 ~tif:Ioc Buy "100100" "0.05";
  [%expect {| (Filled (order_id 4) (total 0.02) (avg_px 100050) (client_order_id ())) |}];
  place ex 1 Buy "99000" "0.01";
  place ex 1 Buy "98000" "0.01";
  print_s
    [%sexp
      (Exchange.place ex (acct 3) (Order_request.market btc Sell ~size:(sz "0.03"))
       : Order_status.t)];
  [%expect
    {|
    (Resting (order_id 5) (client_order_id ()))
    (Resting (order_id 6) (client_order_id ()))
    (Filled (order_id 7) (total 0.02) (avg_px 98500) (client_order_id ()))
    |}];
  print_events ex;
  [%expect
    {|
    accepted 0001 oid=1 A 0.01@100000
    accepted 0002 oid=2 A 0.01@100100
    rejected 0001 Self_trade
    fill tid=1 0.01@100000 taker=0003(Open_long fee 0.35) maker=0001(Open_short fee 0.1)
    filled 0001 oid=1 A 0@100000
    fill tid=2 0.01@100100 taker=0003(Open_long fee 0.35035) maker=0002(Open_short fee 0.1001)
    filled 0002 oid=2 A 0@100100
    cancelled 0003 oid=4 B 0.03@100100 Ioc_unfilled
    accepted 0001 oid=5 B 0.01@99000
    accepted 0001 oid=6 B 0.01@98000
    fill tid=3 0.01@99000 taker=0003(Close_long fee 0.3465) maker=0001(Close_short fee 0.099)
    filled 0001 oid=5 B 0@99000
    fill tid=4 0.01@98000 taker=0003(Close_long fee 0.343) maker=0001(Open_long fee 0.098)
    filled 0001 oid=6 B 0@98000
    cancelled 0003 oid=7 A 0.01@94050 Ioc_unfilled
    |}]
;;

let%expect_test "cancel, cancel by client order id and modify" =
  let ex = fresh () in
  place ex 1 Buy "99000" "0.01" ~cid:(cid 1);
  place ex 1 Buy "98000" "0.01" ~cid:(cid 2);
  place ex 1 Buy "97000" "0.01";
  let cancel n oid =
    print_s
      [%sexp
        (Exchange.cancel ex (acct n) ~symbol:btc (Order_id.of_int oid) : Cancel_status.t)]
  in
  cancel 2 1;
  cancel 1 1;
  cancel 1 1;
  print_s
    [%sexp
      (Exchange.cancel_by_client_order_id ex (acct 1) ~symbol:btc (cid 2)
       : Cancel_status.t)];
  print_s
    [%sexp
      (Exchange.modify
         ex
         (acct 1)
         (Order_id (Order_id.of_int 3))
         (order ~cid:(cid 3) Buy "97500" "0.02")
       : Order_status.t)];
  print_s
    [%sexp
      (Exchange.modify ex (acct 1) (Client_order_id (cid 3)) (order Buy "97600" "0.02")
       : Order_status.t)];
  print_s
    [%sexp
      (Exchange.modify ex (acct 1) (Client_order_id (cid 3)) (order Buy "97600" "0.02")
       : Order_status.t)];
  [%expect
    {|
    (Resting (order_id 1) (client_order_id (c1)))
    (Resting (order_id 2) (client_order_id (c2)))
    (Resting (order_id 3) (client_order_id ()))
    Not_found
    Cancelled
    Not_found
    Cancelled
    (Resting (order_id 4) (client_order_id (c3)))
    (Resting (order_id 5) (client_order_id ()))
    (Rejected Order_not_found)
    |}];
  print_events ex;
  print_s [%sexp (Exchange.open_orders ex (acct 1) : Open_order.t list)];
  [%expect
    {|
    accepted 0001 oid=1 B 0.01@99000
    accepted 0001 oid=2 B 0.01@98000
    accepted 0001 oid=3 B 0.01@97000
    cancelled 0001 oid=1 B 0.01@99000 User
    cancelled 0001 oid=2 B 0.01@98000 User
    cancelled 0001 oid=3 B 0.01@97000 Modified
    accepted 0001 oid=4 B 0.02@97500
    cancelled 0001 oid=4 B 0.02@97500 Modified
    accepted 0001 oid=5 B 0.02@97600
    rejected 0001 Order_not_found
    (((symbol BTC) (side Buy) (px 97600) (size 0.02) (orig_size (0.02))
      (order_id 5) (client_order_id ()) (timestamp 0)))
    |}]
;;

let%expect_test "reduce-only orders are clipped to the position" =
  let ex = fresh () in
  place ex 2 Sell "100000" "0.02";
  place ex 1 Buy "100000" "0.02";
  place ex 3 Buy "99000" "1";
  place ex 1 ~reduce_only:true Sell "99000" "0.05";
  place ex 1 ~reduce_only:true Sell "99000" "0.05";
  [%expect
    {|
    (Resting (order_id 1) (client_order_id ()))
    (Filled (order_id 2) (total 0.02) (avg_px 100000) (client_order_id ()))
    (Resting (order_id 3) (client_order_id ()))
    (Filled (order_id 4) (total 0.02) (avg_px 99000) (client_order_id ()))
    (Rejected Reduce_only_would_increase)
    |}]
;;

let%expect_test "set_mark liquidates and cancels the account's orders" =
  let ex = fresh () in
  Exchange.deposit ex (acct 4) (usd "60");
  place ex 2 Sell "100000" "0.02";
  place ex 4 Buy "100000" "0.01";
  place ex 4 Buy "90000" "0.0002";
  ignore (Exchange.drain_events ex);
  (* BTC max leverage is 40x, so maintenance is 1/80 of notional. Account value is $60 -
     $0.35 fee + 0.01 * (mark - 100000). *)
  Exchange.set_mark ex btc (px "95500");
  print_events ex;
  [%expect
    {|
    (Resting (order_id 1) (client_order_id ()))
    (Filled (order_id 2) (total 0.01) (avg_px 100000) (client_order_id ()))
    (Resting (order_id 3) (client_order_id ()))
    |}];
  Exchange.set_mark ex btc (px "94500");
  print_events ex;
  print_s [%sexp (Exchange.open_orders ex (acct 4) : Open_order.t list)];
  [%expect
    {|
    liquidation 0004 BTC 0.01@94500 pnl -55
    cancelled 0004 oid=3 B 0.0002@90000 Liquidated
    ()
    |}]
;;

let%expect_test "step charges hourly funding" =
  let ex = fresh () in
  place ex 2 Sell "100000" "0.1";
  place ex 1 Buy "100000" "0.1";
  ignore (Exchange.drain_events ex);
  let hour = 3_600_000_000_000 in
  Exchange.step ex ~now:(hour - 1);
  print_events ex;
  [%expect
    {|
    (Resting (order_id 1) (client_order_id ()))
    (Filled (order_id 2) (total 0.1) (avg_px 100000) (client_order_id ()))
    |}];
  Exchange.step ex ~now:(hour + 1);
  print_events ex;
  [%expect {| funding BTC rate=1.25e-05 mark=100000 0001:0.125 0002:-0.125 |}];
  Exchange.set_funding_rate ex btc (-0.0001);
  Exchange.step ex ~now:((3 * hour) + 5);
  print_events ex;
  [%expect
    {|
    funding BTC rate=-0.0001 mark=100000 0001:-1 0002:1
    funding BTC rate=-0.0001 mark=100000 0001:-1 0002:1
    |}]
;;

let%expect_test "funding_rate reads back the default and set rates" =
  let ex = fresh () in
  let eth = Symbol.of_string "ETH" in
  let show () =
    print_s
      [%message
        ""
          ~btc:(Exchange.funding_rate ex btc : float)
          ~eth:(Exchange.funding_rate ex eth : float)]
  in
  show ();
  [%expect {| ((btc 1.25E-05) (eth 1.25E-05)) |}];
  Exchange.set_funding_rate ex btc (-0.0001);
  show ();
  [%expect {| ((btc -0.0001) (eth 1.25E-05)) |}]
;;

let%test_unit "random order flow keeps books uncrossed and conserves value" =
  let gen =
    let open Quickcheck.Generator.Let_syntax in
    List.gen_with_length
      80
      (let%map owner = Int.gen_incl 1 3
       and side = Quickcheck.Generator.of_list Side.all
       and px = Int.gen_incl 990 1010
       and sz = Int.gen_incl 1 20
       and tif = Quickcheck.Generator.of_list Tif.all
       and cancel =
         Quickcheck.Generator.weighted_union
           [ 4., return None; 1., Int.gen_incl 1 80 >>| Option.some ]
       in
       owner, side, px * 100, sz, tif, cancel)
  in
  Quickcheck.test
    ~trials:100
    ~sexp_of:[%sexp_of: (int * Side.t * int * int * Tif.t * int option) list]
    gen
    ~f:(fun ops ->
      let ex = fresh () in
      List.iter ops ~f:(fun (owner, side, p, s, tif, cancel) ->
        (match cancel with
         | Some oid ->
           ignore
             (Exchange.cancel ex (acct owner) ~symbol:btc (Order_id.of_int oid)
              : Cancel_status.t)
         | None ->
           ignore
             (Exchange.place
                ex
                (acct owner)
                (order ~tif side (Int.to_string p) (sprintf "0.%03d" s))
              : Order_status.t));
        Order_book.invariant (Option.value_exn (Exchange.book ex btc)));
      let ch = Exchange.clearinghouse ex in
      let total =
        Usd.sum
          (Clearinghouse.fees_collected ch
           :: List.map [ 1; 2; 3 ] ~f:(fun n ->
             Clearinghouse.equity ch (acct n) ~mark:(Exchange.mark ex)))
      in
      assert (Usd.( <= ) (Usd.abs (Usd.( - ) total (usd "30000"))) (usd "0.0001"));
      (* Every resting order is listed exactly once in its owner's open orders. *)
      let listed =
        List.concat_map [ 1; 2; 3 ] ~f:(fun n -> Exchange.open_orders ex (acct n))
      in
      [%test_result: int]
        (List.length listed)
        ~expect:(Order_book.length (Option.value_exn (Exchange.book ex btc))))
;;
