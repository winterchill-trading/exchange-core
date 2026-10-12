open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

let symbols ex = List.map (Exchange.instruments ex) ~f:(fun (i : Instrument.t) -> i.symbol)

let%expect_test "books rebuilt from drained events match the exchange after every tick" =
  let ex = Exchange.create () in
  let sim =
    Market_sim.create { Market_sim.Config.default with seed = 5; noise_traders = 6 } ex
  in
  let replay = Book_replay.create (symbols ex) in
  let events = ref 0 in
  let mismatches = ref 0 in
  for i = 1 to 500 do
    Market_sim.tick sim;
    Exchange.step ex ~now:(i * 100_000_000);
    let drained = Exchange.drain_numbered_events ex in
    events := !events + List.length drained;
    ok_exn (Book_replay.apply_all replay drained);
    List.iter (symbols ex) ~f:(fun symbol ->
      let expected = Exchange.l2 ex symbol ~n_levels:1_000 in
      let rebuilt =
        Book_replay.l2 replay symbol ~n_levels:1_000 ~time:(Exchange.now ex)
      in
      if not ([%equal: L2.t option] expected rebuilt) then incr mismatches)
  done;
  let depth symbol =
    let l2 = Option.value_exn (Book_replay.l2 replay symbol ~n_levels:1_000 ~time:0) in
    List.length l2.bids, List.length l2.asks
  in
  print_s
    [%message
      ""
        ~events:(!events : int)
        ~next_seq:(Book_replay.next_seq replay : int)
        ~mismatches:(!mismatches : int)
        ~levels:
          (List.map (symbols ex) ~f:(fun s -> s, depth s)
           : (Symbol.t * (int * int)) list)];
  [%expect {|
    ((events 5988) (next_seq 5989) (mismatches 0)
     (levels ((BTC (12 13)) (ETH (17 14)) (SOL (16 15)))))
    |}]
;;

let%expect_test "liquidation cancels reach the rebuilt book" =
  let ex = Exchange.create () in
  let replay = Book_replay.create (symbols ex) in
  let a = acct 1
  and b = acct 2 in
  Exchange.deposit ex a (usd "1000");
  Exchange.deposit ex b (usd "1000000");
  let place who side p s =
    ignore
      (Exchange.place ex who (Order_request.limit btc side ~px:(px p) ~size:(sz s))
       : Order_status.t)
  in
  place b Sell "100000" "0.1";
  place a Buy "100000" "0.1";
  place a Buy "90000" "0.01";
  place b Buy "95000" "0.01";
  Exchange.set_mark ex btc (px "99000");
  Exchange.set_mark ex btc (px "80000");
  let drained = Exchange.drain_numbered_events ex in
  ok_exn (Book_replay.apply_all replay drained);
  let show l2 = Option.map l2 ~f:(fun (l2 : L2.t) -> l2.bids, l2.asks) in
  print_s
    [%message
      ""
        ~exchange:
          (show (Exchange.l2 ex btc) : (L2.Level.t list * L2.Level.t list) option)
        ~rebuilt:
          (show (Book_replay.l2 replay btc ~n_levels:20 ~time:0)
           : (L2.Level.t list * L2.Level.t list) option)];
  [%expect {|
    ((exchange (((((px 95000) (sz 0.01) (n 1))) ())))
     (rebuilt (((((px 95000) (sz 0.01) (n 1))) ()))))
    |}]
;;

let%expect_test "gaps and unknown orders are errors" =
  let ex = Exchange.create () in
  Exchange.deposit ex (acct 1) (usd "100000");
  ignore
    (Exchange.place
       ex
       (acct 1)
       (Order_request.limit btc Buy ~px:(px "100") ~size:(sz "1"))
     : Order_status.t);
  ignore (Exchange.cancel ex (acct 1) ~symbol:btc (Order_id.of_int 1) : Cancel_status.t);
  let accepted, cancelled =
    match Exchange.drain_numbered_events ex with
    | [ accepted; cancelled ] -> accepted, cancelled
    | events -> raise_s [%sexp (events : Event.Numbered.t list)]
  in
  let replay = Book_replay.create (symbols ex) in
  print_s [%sexp (Book_replay.apply replay cancelled : unit Or_error.t)];
  [%expect {| (Error ("Book_replay: sequence gap" (expected 1) (got 2))) |}];
  print_s
    [%sexp (Book_replay.apply_all replay [ accepted; accepted ] : unit Or_error.t)];
  [%expect {| (Error ("Book_replay: sequence gap" (expected 2) (got 1))) |}];
  (* Starting mid-stream, the cancel of an order never seen is ignored. *)
  let replay = Book_replay.create ~next_seq:2 (symbols ex) in
  print_s [%sexp (Book_replay.apply replay cancelled : unit Or_error.t)];
  [%expect {| (Ok ()) |}]
;;
