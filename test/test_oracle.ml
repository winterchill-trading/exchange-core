open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

let hour = Time_ns.Span.to_int_ns Time_ns.Span.hour

let place ex n side p s =
  ignore
    (Exchange.place ex (acct n) (Order_request.limit btc side ~px:(px p) ~size:(sz s))
     : Order_status.t)
;;

(* A book quoted 0.2-0.3% above the oracle; account 1 long 0.1 BTC from account 3. *)
let rich_book () =
  let ex = Exchange.create () in
  List.iter [ 1; 2; 3 ] ~f:(fun n -> Exchange.deposit ex (acct n) (usd "100000"));
  place ex 2 Buy "100200" "1";
  place ex 3 Sell "100300" "1.1";
  place ex 1 Buy "100300" "0.1";
  ignore (Exchange.drain_events ex : Event.t list);
  ex
;;

let show ex =
  print_s
    [%message
      ""
        ~oracle:(Exchange.oracle ex btc : Price.t option)
        ~mark:(Exchange.mark ex btc : Price.t option)
        ~premium:(Exchange.premium ex btc : float option)
        ~funding_rate:(Exchange.funding_rate ex btc : float)
        ~impact_pxs:(Exchange.impact_pxs ex btc : float option * float option)]
;;

let%expect_test "the oracle sets the mark, the premium sets funding" =
  let ex = rich_book () in
  show ex;
  Exchange.set_oracle ex btc (px "100000");
  show ex;
  Exchange.step ex ~now:(hour / 2);
  show ex;
  Exchange.step ex ~now:hour;
  List.iter (Exchange.drain_events ex) ~f:(function
    | Funding { rate; mark; payments; _ } ->
      print_s
        [%message
          "funding"
            (rate : float)
            ~px:(mark : Price.t)
            (payments : Clearinghouse.Funding_payment.t list)]
    | _ -> ());
  (* The samples start again after a payment. *)
  show ex;
  [%expect
    {|
    ((oracle ()) (mark (100300)) (premium ()) (funding_rate 1.25E-05)
     (impact_pxs ((100200) (100300))))
    ((oracle (100000)) (mark (100300)) (premium ()) (funding_rate 1.25E-05)
     (impact_pxs ((100200) (100300))))
    ((oracle (100000)) (mark (100300)) (premium (0.002))
     (funding_rate 0.00018750000000000017) (impact_pxs ((100200) (100300))))
    (funding (rate 0.00018750000000000017) (px 100000)
     (payments
      (((account 0x0000000000000000000000000000000000000001) (symbol BTC)
        (size 0.1) (payment 1.875))
       ((account 0x0000000000000000000000000000000000000003) (symbol BTC)
        (size -0.1) (payment -1.875)))))
    ((oracle (100000)) (mark (100300)) (premium (0.002)) (funding_rate 1.25E-05)
     (impact_pxs ((100200) (100300))))
    |}]
;;

let%expect_test "a set funding rate overrides the premium" =
  let ex = rich_book () in
  Exchange.set_oracle ex btc (px "100000");
  Exchange.set_funding_rate ex btc 0.00001;
  Exchange.step ex ~now:(hour / 4);
  show ex;
  [%expect
    {|
    ((oracle (100000)) (mark (100300)) (premium (0.002)) (funding_rate 1E-05)
     (impact_pxs ((100200) (100300))))
    |}]
;;

let%expect_test "market simulation publishing an oracle replays exactly" =
  let config =
    { Market_sim.Config.default with oracle_interval = Some (Time_ns.Span.of_int_sec 3) }
  in
  let run () =
    let ex = Exchange.create () in
    let inputs = Queue.create () in
    Exchange.record_inputs ex ~f:(Queue.enqueue inputs);
    let sim = Market_sim.create config ex in
    let tick = Time_ns.Span.to_int_ns config.tick_interval in
    let oracle_updates = ref 0 in
    Exchange.record_inputs ex ~f:(function
      | Set_oracle _ -> incr oracle_updates
      | _ -> ());
    for i = 1 to 2 * 36_000 do
      Exchange.step ex ~now:(i * tick);
      Market_sim.tick sim
    done;
    ex, Queue.to_list inputs, !oracle_updates
  in
  let ex, inputs, oracle_updates = run () in
  let events = Exchange.drain_events ex in
  let fundings =
    List.filter_map events ~f:(function
      | Funding { symbol; rate; mark; _ } -> Some (symbol, rate, mark)
      | _ -> None)
  in
  print_s
    [%message
      ""
        (oracle_updates : int)
        ~btc_oracle:(Exchange.oracle ex btc : Price.t option)
        ~btc_mark:(Exchange.mark ex btc : Price.t option)
        (fundings : (Symbol.t * float * Price.t) list)];
  let replayed = Journal.replay inputs in
  print_s
    [%message
      ""
        ~identical:
          ([%equal: Sexp.t list]
             (List.map events ~f:[%sexp_of: Event.t])
             (List.map (Exchange.drain_events replayed) ~f:[%sexp_of: Event.t])
           : bool)];
  [%expect
    {|
    ((oracle_updates 7200) (btc_oracle (97735.7)) (btc_mark (97775.1))
     (fundings
      ((BTC 1.25E-05 104824.1) (ETH 1.25E-05 3429.43) (SOL 1.25E-05 152.0819)
       (BTC 1.25E-05 97735.7) (ETH 1.25E-05 3543.34) (SOL 1.25E-05 151.4606))))
    (identical true)
    |}]
;;
