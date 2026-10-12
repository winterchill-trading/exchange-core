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

let%expect_test "randomize: the same seed gives the same config, others differ" =
  let show seed =
    let c = Market_sim.Config.randomize ~seed in
    let r x ~digits = Float.round_decimal x ~decimal_digits:digits in
    print_s
      [%message
        ""
          (seed : int)
          ~vol_bps:(r c.vol_bps ~digits:2 : float)
          ~traders:(c.noise_traders : int)
          ~post:(r c.post_probability ~digits:3 : float)
          ~cancel:(r c.cancel_probability ~digits:3 : float)
          ~market:(r c.market_probability ~digits:4 : float)
          ~inside:(r c.inside_touch_probability ~digits:3 : float)
          ~offset_bps:(r c.max_offset_bps ~digits:2 : float)]
  in
  List.iter [ 1; 2; 3 ] ~f:show;
  [%expect
    {|
    ((seed 1) (vol_bps 16.75) (traders 11) (post 0.286) (cancel 0.258)
     (market 0.0333) (inside 0.024) (offset_bps 5.21))
    ((seed 2) (vol_bps 9.03) (traders 15) (post 0.319) (cancel 0.287)
     (market 0.0101) (inside 0.067) (offset_bps 6.55))
    ((seed 3) (vol_bps 7.9) (traders 12) (post 0.179) (cancel 0.133)
     (market 0.0217) (inside 0.105) (offset_bps 29.65))
    |}];
  let config seed = [%sexp_of: Market_sim.Config.t] (Market_sim.Config.randomize ~seed) in
  print_s [%sexp (Sexp.equal (config 42) (config 42) : bool)];
  [%expect {| true |}]
;;

(* Mean quoted spread of BTC in bps over a run; raises if the book ever crosses. *)
let spread_stats config =
  let exchange = Exchange.create () in
  let sim = Market_sim.create config exchange in
  let btc = Symbol.of_string "BTC" in
  let spreads = ref [] in
  for i = 1 to 600 do
    Market_sim.tick sim;
    Exchange.step exchange ~now:(i * 100_000_000);
    ignore (Exchange.drain_events exchange : Event.t list);
    let book = Option.value_exn (Exchange.book exchange btc) in
    Order_book.invariant book;
    match Order_book.best_bid book, Order_book.best_ask book with
    | Some bid, Some ask ->
      let bid = Price.to_float bid
      and ask = Price.to_float ask in
      spreads := ((ask -. bid) /. ((ask +. bid) /. 2.) *. 10_000.) :: !spreads
    | _ -> ()
  done;
  let n = List.length !spreads in
  Float.round_decimal
    (List.sum (module Float) !spreads ~f:Fn.id /. Float.of_int n)
    ~decimal_digits:2
;;

let%expect_test "inside-touch orders tighten the spread" =
  let base = { Market_sim.Config.default with seed = 9; noise_traders = 6 } in
  print_s
    [%message
      ""
        ~without:(spread_stats base : float)
        ~with_inside_touch:
          (spread_stats { base with inside_touch_probability = 0.2 } : float)];
  [%expect {| ((without 5.23) (with_inside_touch 0.39)) |}]
;;

let%expect_test "randomized configs run and keep the book uncrossed" =
  List.iter [ 1; 2; 3 ] ~f:(fun seed ->
    let spread = spread_stats (Market_sim.Config.randomize ~seed) in
    print_s [%message (seed : int) (spread : float)]);
  [%expect
    {|
    ((seed 1) (spread 3.53))
    ((seed 2) (spread 0.88))
    ((seed 3) (spread 0.67))
    |}]
;;

let btc = Symbol.of_string "BTC"

let%expect_test "set_reference without a half-life pins the reference and the mark" =
  let exchange = Exchange.create () in
  let sim =
    Market_sim.create
      { Market_sim.Config.default with seed = 5; noise_traders = 3 }
      exchange
  in
  for _ = 1 to 10 do
    Market_sim.tick sim
  done;
  Market_sim.set_reference sim btc (Price.of_string "101234.5");
  let show () =
    print_s
      [%message
        ""
          ~reference:(Market_sim.reference_price sim btc : Price.t option)
          ~mark:(Exchange.mark exchange btc : Price.t option)]
  in
  show ();
  for _ = 1 to 20 do
    Market_sim.tick sim
  done;
  show ();
  Market_sim.clear_reference sim btc;
  for _ = 1 to 20 do
    Market_sim.tick sim
  done;
  show ();
  [%expect
    {|
    ((reference (101234.5)) (mark (101234.5)))
    ((reference (101234.5)) (mark (101234.5)))
    ((reference (101170.2)) (mark (101170.2)))
    |}]
;;

let%expect_test "with a half-life the walk converges towards the anchor" =
  let gaps ~vol_bps =
    let exchange = Exchange.create () in
    let sim =
      Market_sim.create
        { Market_sim.Config.default with seed = 5; noise_traders = 0; vol_bps }
        exchange
    in
    let anchor = Price.of_int 110_000 in
    (* 100ms ticks, so a 1s half-life is 10 ticks. *)
    Market_sim.set_reference sim btc anchor ~half_life:(Time_ns.Span.of_sec 1.);
    List.map [ 10; 10; 10; 30; 140 ] ~f:(fun n ->
      for _ = 1 to n do
        Market_sim.tick sim
      done;
      let reference = Option.value_exn (Market_sim.reference_price sim btc) in
      Float.iround_nearest_exn (Price.to_float (Price.( - ) anchor reference)))
  in
  print_s
    [%message
      "gap to the anchor after 10, 20, 30, 60 and 200 ticks"
        ~no_noise:(gaps ~vol_bps:0. : int list)
        ~default_noise:(gaps ~vol_bps:5. : int list)];
  [%expect
    {|
    ("gap to the anchor after 10, 20, 30, 60 and 200 ticks"
     (no_noise (5000 2500 1250 156 0)) (default_noise (5028 2434 1192 96 -61)))
    |}]
;;

let%expect_test "an anchored stepped run replays bit for bit from its journal" =
  let path = "test_market_sim_anchor.bin" in
  let journal = Journal.create path in
  let stepped =
    Stepped.create
      ~journal
      { Stepped.Config.default with
        sim = Some { Market_sim.Config.default with seed = 21; noise_traders = 4 }
      }
  in
  let sim = Option.value_exn (Stepped.sim stepped) in
  Stepped.run stepped ~steps:300 ~f:(fun t _ ->
    match Stepped.steps t with
    | 50 -> Market_sim.set_reference sim btc (Price.of_int 100_500)
    | 100 ->
      Market_sim.set_reference
        sim
        btc
        (Price.of_int 99_000)
        ~half_life:(Time_ns.Span.of_int_ms 500)
    | 200 -> Market_sim.clear_reference sim btc
    | _ -> ());
  Journal.close journal;
  let inputs = Journal.load path |> ok_exn in
  Stdlib.Sys.remove path;
  let replayed = Journal.replay inputs in
  let original =
    List.map (Stepped.events stepped) ~f:(fun e -> Event.sexp_of_t e.event)
  in
  let replayed_events =
    List.take
      (List.map (Exchange.drain_events replayed) ~f:Event.sexp_of_t)
      (List.length original)
  in
  print_s
    [%message
      ""
        ~inputs:(List.length inputs : int)
        ~events:(List.length original : int)
        ~identical:([%equal: Sexp.t list] original replayed_events : bool)
        ~check_replay:(Stepped.check_replay stepped : unit Or_error.t)];
  [%expect {| ((inputs 3241) (events 2250) (identical true) (check_replay (Ok ()))) |}]
;;
