open! Core
open! Exchange_core
open! Exchange_core_engine

let run ~seed ~ticks =
  let exchange = Exchange.create () in
  let sim =
    Market_sim.create { Market_sim.Config.default with seed; noise_traders = 4 } exchange
  in
  let counts = String.Table.create () in
  for i = 1 to ticks do
    Market_sim.tick sim;
    Exchange.step exchange ~now:(i * 100_000_000);
    List.iter (Exchange.drain_events exchange) ~f:(fun e ->
      let name =
        match e with
        | Order_rejected { reason; _ } ->
          "rejected: " ^ Sexp.to_string [%sexp (reason : Reject_reason.t)]
        | _ ->
          (match [%sexp_of: Event.t] e with
           | List (Atom name :: _) | Atom name -> name
           | List _ -> "?")
      in
      Hashtbl.incr counts name)
  done;
  exchange, sim, counts
;;

let%expect_test "noise traders keep a two-sided book around the reference price" =
  let exchange, sim, counts = run ~seed:7 ~ticks:200 in
  let btc = Symbol.of_string "BTC" in
  let book = Option.value_exn (Exchange.l2 exchange btc ~n_levels:3) in
  print_s
    [%message
      ""
        ~reference:(Market_sim.reference_price sim btc : Price.t option)
        ~best_bid:(L2.best_bid book : L2.Level.t option)
        ~best_ask:(L2.best_ask book : L2.Level.t option)
        ~events:
          (Hashtbl.to_alist counts |> List.sort ~compare:[%compare: string * int]
           : (string * int) list)];
  [%expect
    {|
    ((reference (99798.5)) (best_bid (((px 99764.9) (sz 0.00383) (n 1))))
     (best_ask (((px 99853.3) (sz 0.01277) (n 1))))
     (events
      ((Fill 65) (Order_accepted 718) (Order_cancelled 640) (Order_filled 67)
       ("rejected: No_liquidity" 2) ("rejected: Self_trade" 12))))
    |}]
;;

let%expect_test "same seed, same run" =
  let digest seed =
    let exchange, _, _ = run ~seed ~ticks:50 in
    Exchange.mids exchange
  in
  print_s [%sexp ([%equal: (Symbol.t * Price.t) list] (digest 3) (digest 3) : bool)];
  [%expect {| true |}];
  print_s [%sexp ([%equal: (Symbol.t * Price.t) list] (digest 3) (digest 4) : bool)];
  [%expect {| false |}]
;;

let%expect_test "default prices recognise the base asset by prefix" =
  List.map
    [ "BTC"; "BTCUSDT"; "BTC-PERP"; "eth"; "ETHUSDT"; "SOL-PERP"; "DOGE" ]
    ~f:Symbol.of_string
  |> Market_sim.Config.default_prices
  |> [%sexp_of: (Symbol.t * Price.t) list]
  |> print_s;
  [%expect
    {|
    ((BTC 100000) (BTCUSDT 100000) (BTC-PERP 100000) (eth 3500) (ETHUSDT 3500)
     (SOL-PERP 150) (DOGE 100))
    |}]
;;

let%expect_test "coarse lot sizes and unlisted symbols still trade" =
  let instrument name size_decimals tick =
    Instrument.create
      (Symbol.of_string name)
      ~size_decimals
      ~price_tick:(Price.of_string tick)
      ~max_leverage:20
  in
  let instruments =
    [ instrument "BTCUSDT" 3 "0.1"
    ; instrument "ETHUSDT" 2 "0.01"
    ; instrument "SOLUSDT" 0 "0.01"
    ]
  in
  let exchange =
    Exchange.create ~config:{ Exchange.Config.default with instruments } ()
  in
  let sim =
    Market_sim.create
      { Market_sim.Config.default with initial_prices = []; noise_traders = 4 }
      exchange
  in
  let sizes = Symbol.Table.create () in
  for i = 1 to 100 do
    Market_sim.tick sim;
    Exchange.step exchange ~now:(i * 100_000_000);
    List.iter (Exchange.drain_events exchange) ~f:(function
      | Order_accepted { order; _ } ->
        Hashtbl.update sizes order.symbol ~f:(fun prev ->
          let lo, hi = Option.value prev ~default:(order.size, order.size) in
          Size.min lo order.size, Size.max hi order.size)
      | Order_rejected { reason = Invalid_size; _ } -> print_endline "invalid size"
      | _ -> ())
  done;
  List.iter instruments ~f:(fun i ->
    print_s
      [%message
        ""
          ~symbol:(i.symbol : Symbol.t)
          ~reference:(Market_sim.reference_price sim i.symbol : Price.t option)
          ~accepted_size_range:(Hashtbl.find sizes i.symbol : (Size.t * Size.t) option)]);
  [%expect
    {|
    ((symbol BTCUSDT) (reference (99840)) (accepted_size_range ((0.003 0.099))))
    ((symbol ETHUSDT) (reference (3496.39)) (accepted_size_range ((0.01 0.99))))
    ((symbol SOLUSDT) (reference (150.06)) (accepted_size_range ((1 98))))
    |}]
;;
