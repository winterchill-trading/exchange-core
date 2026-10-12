open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

let me = acct 7

(* A toy market maker: every 10 steps, cancel its quotes and quote one lot each side, 5
   bps around the mid. *)
let quoter (h : Stepped.t) (_ : Event.Numbered.t list) =
  let ex = Stepped.exchange h in
  if Stepped.steps h % 10 = 1
  then (
    List.iter (Exchange.open_orders ex me) ~f:(fun o ->
      ignore (Exchange.cancel ex me ~symbol:o.symbol o.order_id : Cancel_status.t));
    Option.iter
      (Option.bind (Exchange.book ex btc) ~f:Order_book.mid)
      ~f:(fun mid ->
        let mid = Price.to_float mid in
        let instrument = Option.value_exn (Exchange.instrument ex btc) in
        List.iter
          [ Side.Buy, mid *. 0.9995; Sell, mid *. 1.0005 ]
          ~f:(fun (side, p) ->
            ignore
              (Exchange.place
                 ex
                 me
                 (Order_request.limit
                    btc
                    side
                    ~px:(Instrument.round_price instrument p)
                    ~size:(sz "0.01"))
               : Order_status.t))))
;;

let run ?journal () =
  let config =
    { Stepped.Config.default with
      sim = Some { Market_sim.Config.default with seed = 3; noise_traders = 5 }
    }
  in
  let h = Stepped.create ?journal config in
  Exchange.deposit (Stepped.exchange h) me (usd "100000");
  Stepped.run h ~steps:600 ~f:quoter;
  h
;;

let summary h =
  let ex = Stepped.exchange h in
  let my_fills =
    List.count (Stepped.events h) ~f:(fun { event; _ } ->
      match event with
      | Fill { fill; _ } -> Account.equal fill.maker me || Account.equal fill.taker me
      | _ -> false)
  in
  let view = Exchange.account_view ex me in
  [%message
    ""
      ~steps:(Stepped.steps h : int)
      ~now_s:(Exchange.now ex / 1_000_000_000 : int)
      ~inputs:(List.length (Stepped.inputs h) : int)
      ~events:(List.length (Stepped.events h) : int)
      (my_fills : int)
      ~position:
        (List.map view.positions ~f:(fun p -> p.symbol, p.size)
         : (Symbol.t * Size.t) list)
      ~equity:(view.equity : Usd.t)]
;;

let%expect_test "a quoting strategy in the stepped harness" =
  let h = run () in
  print_s (summary h);
  [%expect
    {|
    ((steps 600) (now_s 60) (inputs 7887) (events 5983) (my_fills 32)
     (position ((BTC 0.02528))) (equity 100002.85050817))
    |}];
  print_s [%sexp (Stepped.check_replay h : unit Or_error.t)];
  [%expect {| (Ok ()) |}]
;;

let%expect_test "runs are repeatable and the journal file replays them" =
  let path = "test_stepped.bin" in
  let journal = Journal.create path in
  let h = run ~journal () in
  Journal.close journal;
  let again = run () in
  print_s [%sexp (Sexp.equal (summary h) (summary again) : bool)];
  [%expect {| true |}];
  let inputs = ok_exn (Journal.load path) in
  Stdlib.Sys.remove path;
  print_s [%sexp ([%equal: Input.t list] inputs (Stepped.inputs h) : bool)];
  [%expect {| true |}];
  let replayed = Journal.replay ~config:(Stepped.config h).exchange inputs in
  print_s
    [%sexp
      ([%equal: Account_view.t]
         (Exchange.account_view replayed me)
         (Exchange.account_view (Stepped.exchange h) me)
       : bool)];
  [%expect {| true |}]
;;

let%expect_test "a tampered input stream diverges" =
  let h = run () in
  let inputs = Stepped.inputs h in
  let tampered =
    List.map inputs ~f:(function
      | Deposit { account; usd = _ } when Account.equal account me ->
        Input.Deposit { account; usd = usd "10" }
      | input -> input)
  in
  let replayed = Journal.replay tampered in
  let differs =
    not
      ([%equal: Account_view.t]
         (Exchange.account_view replayed me)
         (Exchange.account_view (Stepped.exchange h) me))
  in
  print_s [%sexp (differs : bool)];
  [%expect {| true |}]
;;
