open! Core
open! Exchange_core
open Helpers

let tier lower_bound max_leverage =
  { Margin_tier.lower_bound = usd lower_bound; max_leverage }
;;

(* Hyperliquid's mainnet BTC tiers, and its testnet ETH tiers (three tiers). *)
let btc_tiers = [ tier "0" 40; tier "150000000" 20 ]
let eth_testnet = [ tier "0" 25; tier "20000" 10; tier "50000" 5 ]

let%expect_test "maintenance margin is continuous across tiers" =
  let show tiers notional =
    let notional = usd notional in
    printf
      "%12s  %3dx  %s\n"
      (Usd.to_string notional)
      (Margin_tier.find tiers ~notional).max_leverage
      (Usd.to_string (Margin_tier.maintenance tiers ~notional))
  in
  List.iter [ "1000"; "150000000"; "150000001"; "200000000" ] ~f:(show btc_tiers);
  [%expect
    {|
         1000   40x  12.5
    150000000   40x  1875000
    150000001   20x  1875000.025
    200000000   20x  3125000
    |}];
  List.iter
    [ "10000"; "20000"; "20001"; "50000"; "50001"; "100000" ]
    ~f:(show eth_testnet);
  [%expect
    {|
     10000   25x  200
     20000   25x  400
     20001   10x  400.05
     50000   10x  1900
     50001    5x  1900.1
    100000    5x  6900
    |}]
;;

let%expect_test "validation" =
  let check tiers =
    match Margin_tier.validate tiers with
    | () -> print_endline "ok"
    | exception exn -> print_s (Exn.sexp_of_t exn)
  in
  check btc_tiers;
  check [];
  check [ tier "10" 40 ];
  check [ tier "0" 40; tier "100" 40 ];
  check [ tier "0" 40; tier "0" 20 ];
  [%expect
    {|
    ok
    "Margin_tier: no tiers"
    ("Margin_tier: the first tier must start at zero"
     (first ((lower_bound 10) (max_leverage 40))))
    ("Margin_tier: bounds must increase and leverages decrease"
     (a ((lower_bound 0) (max_leverage 40)))
     (b ((lower_bound 100) (max_leverage 40))))
    ("Margin_tier: bounds must increase and leverages decrease"
     (a ((lower_bound 0) (max_leverage 40)))
     (b ((lower_bound 0) (max_leverage 20))))
    |}];
  (match
     Instrument.create
       ~margin_tiers:btc_tiers
       (Symbol.of_string "BTC")
       ~size_decimals:5
       ~price_tick:(px "0.1")
       ~max_leverage:50
   with
   | _ -> print_endline "created"
   | exception exn -> print_s (Exn.sexp_of_t exn));
  [%expect
    {|
    ("Instrument.create: the first margin tier's leverage must be max_leverage"
     (max_leverage 50) (first ((lower_bound 0) (max_leverage 40))))
    |}]
;;

let%expect_test "an exchange with margin tiers" =
  let btc_tiered =
    Instrument.create
      ~margin_tiers:[ tier "0" 40; tier "10000" 25; tier "50000" 10 ]
      btc
      ~size_decimals:5
      ~price_tick:(px "0.1")
      ~max_leverage:40
  in
  let ex =
    Exchange_core_engine.Exchange.create
      ~config:
        { Exchange_core_engine.Exchange.Config.default with instruments = [ btc_tiered ] }
      ()
  in
  let module Exchange = Exchange_core_engine.Exchange in
  List.iter [ 1; 2 ] ~f:(fun n -> Exchange.deposit ex (acct n) (usd "100000"));
  let leverage n l =
    print_s [%sexp (Exchange.set_leverage ex (acct n) btc l : unit Or_error.t)]
  in
  (* Flat: any leverage up to the first tier's. *)
  leverage 1 40;
  ignore
    (Exchange.place
       ex
       (acct 2)
       (Order_request.limit btc Sell ~px:(px "100000") ~size:(sz "0.3"))
     : Order_status.t);
  ignore
    (Exchange.place
       ex
       (acct 1)
       (Order_request.limit btc Buy ~px:(px "100000") ~size:(sz "0.3"))
     : Order_status.t);
  (* A 30,000 position sits in the 25x tier. *)
  leverage 1 40;
  leverage 1 25;
  let view = Exchange.account_view ex (acct 1) in
  print_s
    [%message
      ""
        ~maintenance:(view.maintenance_margin : Usd.t)
        ~liquidation_px:
          (List.map view.positions ~f:(fun p -> p.liquidation_px) : Price.t option list)];
  [%expect
    {|
    (Ok ())
    (Error
     ("Leverage above the margin tier of the position" (symbol BTC) (leverage 40)
      (max_leverage 25) (notional 30000)))
    (Ok ())
    ((maintenance 525) (liquidation_px (())))
    |}]
;;
