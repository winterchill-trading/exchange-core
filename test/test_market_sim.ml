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
