open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

let maker = acct 1
let taker = acct 2
let eth = Symbol.of_string "ETH"
let minute = Time_ns.Span.to_int_ns Time_ns.Span.minute

let rule ?(scope = Halt_rule.Scope.Market_wide) ?(reopen = Halt_rule.Reopen.Automatic) ()
  : Halt_rule.Config.t
  =
  { levels =
      [ { move_bps = 700; duration_ns = Some (15 * minute) }
      ; { move_bps = 1300; duration_ns = Some (15 * minute) }
      ; { move_bps = 2000; duration_ns = None }
      ]
  ; scope
  ; watch = [ btc ]
  ; observe = Mark
  ; reopen
  }
;;

let fresh ?scope ?reopen () =
  let ex = Exchange.create () in
  List.iter [ maker; taker ] ~f:(fun a -> Exchange.deposit ex a (usd "10000000"));
  List.iter
    [ btc, "1000"; eth, "100" ]
    ~f:(fun (symbol, p) ->
      let p = px p in
      let place side px =
        ignore
          (Exchange.place ex maker (Order_request.limit symbol side ~px ~size:(sz "1"))
           : Order_status.t)
      in
      place Sell p;
      place Buy (Price.( - ) p (px "1")));
  Exchange.set_mark ex btc (px "1000");
  ok_exn (Exchange.set_halt_rule ex (Some (rule ?scope ?reopen ())));
  Exchange.set_session_reference ex btc (px "1000");
  ignore (Exchange.drain_events ex : Event.t list);
  ex
;;

let show_guard ex =
  List.iter (Exchange.drain_guard_events ex) ~f:(fun (g : Guard_event.t) ->
    print_s
      [%sexp
        (Symbol.to_string g.symbol : string)
        , (g.time / minute : int)
        , (g.kind : Guard_event.Kind.t)])
;;

let status ex =
  List.iter [ btc; eth ] ~f:(fun symbol ->
    print_s
      [%sexp
        (Symbol.to_string symbol : string)
        , (Exchange.halt_status ex symbol
           : [ `Until of int | `Until_reopen | `Reopen_pending ] option)])
;;

let place ex symbol req =
  print_s [%sexp (Exchange.place ex taker (req symbol) : Order_status.t)]
;;

let%expect_test "market-wide: a 7% move halts every symbol for 15 minutes" =
  let ex = fresh () in
  Exchange.set_mark ex btc (px "935");
  show_guard ex;
  [%expect {| |}];
  Exchange.set_mark ex btc (px "929");
  show_guard ex;
  status ex;
  [%expect
    {|
    (BTC 0
     (Halted (trigger_symbol BTC) (level 0) (reference 1000) (px 929)
      (move_bps 710) (until (900000000000))))
    (ETH 0
     (Halted (trigger_symbol BTC) (level 0) (reference 1000) (px 929)
      (move_bps 710) (until (900000000000))))
    (SOL 0
     (Halted (trigger_symbol BTC) (level 0) (reference 1000) (px 929)
      (move_bps 710) (until (900000000000))))
    (BTC ((Until 900000000000)))
    (ETH ((Until 900000000000)))
    |}];
  (* Orders that would trade are rejected; passive ones rest; cancels work. *)
  place ex eth (fun s -> Order_request.market s Buy ~size:(sz "0.5"));
  place ex eth (fun s -> Order_request.limit s Buy ~px:(px "100") ~size:(sz "0.5"));
  place ex eth (fun s -> Order_request.limit s Buy ~px:(px "98") ~size:(sz "0.5"));
  show_guard ex;
  print_s [%sexp (Exchange.guard_stats ex : Guard_event.Stats.t)];
  [%expect
    {|
    (Rejected (Unsupported "trading halted"))
    (Rejected (Unsupported "trading halted"))
    (Resting (order_id 7) (client_order_id ()))
    (ETH 0 (Halt_rejected (side Buy)))
    (ETH 0 (Halt_rejected (side Buy)))
    ((collar_rejected 0) (collar_repriced 0) (collar_unreferenced 0)
     (halt_rejected 2) (halts 3) (reopens 0))
    |}];
  Exchange.step ex ~now:(14 * minute);
  status ex;
  Exchange.step ex ~now:(15 * minute);
  show_guard ex;
  status ex;
  place ex eth (fun s -> Order_request.limit s Buy ~px:(px "100") ~size:(sz "0.5"));
  [%expect
    {|
    (BTC ((Until 900000000000)))
    (ETH ((Until 900000000000)))
    (BTC 15 Reopened)
    (ETH 15 Reopened)
    (SOL 15 Reopened)
    (BTC ())
    (ETH ())
    (Filled (order_id 8) (total 0.5) (avg_px 100) (client_order_id ()))
    |}]
;;

let%expect_test "levels trigger once per session; the last one waits for reopen" =
  let ex = fresh () in
  Exchange.set_mark ex btc (px "920");
  Exchange.step ex ~now:(15 * minute);
  (* Level 1 already used: a further 7% does nothing until 13%. *)
  Exchange.set_mark ex btc (px "900");
  Exchange.set_mark ex btc (px "860");
  Exchange.step ex ~now:(30 * minute);
  Exchange.set_mark ex btc (px "790");
  Exchange.step ex ~now:(600 * minute);
  show_guard ex;
  status ex;
  [%expect
    {|
    (BTC 0
     (Halted (trigger_symbol BTC) (level 0) (reference 1000) (px 920)
      (move_bps 800) (until (900000000000))))
    (ETH 0
     (Halted (trigger_symbol BTC) (level 0) (reference 1000) (px 920)
      (move_bps 800) (until (900000000000))))
    (SOL 0
     (Halted (trigger_symbol BTC) (level 0) (reference 1000) (px 920)
      (move_bps 800) (until (900000000000))))
    (BTC 15 Reopened)
    (ETH 15 Reopened)
    (SOL 15 Reopened)
    (BTC 15
     (Halted (trigger_symbol BTC) (level 1) (reference 1000) (px 860)
      (move_bps 1400) (until (1800000000000))))
    (ETH 15
     (Halted (trigger_symbol BTC) (level 1) (reference 1000) (px 860)
      (move_bps 1400) (until (1800000000000))))
    (SOL 15
     (Halted (trigger_symbol BTC) (level 1) (reference 1000) (px 860)
      (move_bps 1400) (until (1800000000000))))
    (BTC 30 Reopened)
    (ETH 30 Reopened)
    (SOL 30 Reopened)
    (BTC 30
     (Halted (trigger_symbol BTC) (level 2) (reference 1000) (px 790)
      (move_bps 2100) (until ())))
    (ETH 30
     (Halted (trigger_symbol BTC) (level 2) (reference 1000) (px 790)
      (move_bps 2100) (until ())))
    (SOL 30
     (Halted (trigger_symbol BTC) (level 2) (reference 1000) (px 790)
      (move_bps 2100) (until ())))
    (BTC (Until_reopen))
    (ETH (Until_reopen))
    |}];
  (* A new session re-arms the levels; reopen lifts the halt. *)
  Exchange.set_session_reference ex btc (px "790");
  Exchange.reopen ex;
  show_guard ex;
  status ex;
  [%expect
    {|
    (BTC 600 Reopened)
    (ETH 600 Reopened)
    (SOL 600 Reopened)
    (BTC ())
    (ETH ())
    |}]
;;

let%expect_test "per symbol, reopening on request (a reopening auction hook)" =
  let ex = fresh ~scope:Per_symbol ~reopen:On_request () in
  Exchange.set_mark ex btc (px "1080");
  Exchange.step ex ~now:(16 * minute);
  show_guard ex;
  status ex;
  [%expect
    {|
    (BTC 0
     (Halted (trigger_symbol BTC) (level 0) (reference 1000) (px 1080)
      (move_bps 800) (until (900000000000))))
    (BTC 16 Reopen_pending)
    (BTC (Reopen_pending))
    (ETH ())
    |}];
  Exchange.reopen ~symbol:btc ex;
  show_guard ex;
  status ex;
  [%expect {|
    (BTC 16 Reopened)
    (BTC ())
    (ETH ())
    |}]
;;

let%expect_test "halt rule journal replay" =
  let ex = Exchange.create () in
  let inputs = Queue.create () in
  Exchange.record_inputs ex ~f:(Queue.enqueue inputs);
  ok_exn (Exchange.set_halt_rule ex (Some (rule ())));
  Exchange.set_mark ex btc (px "1000");
  Exchange.set_mark ex btc (px "900");
  Exchange.step ex ~now:(20 * minute);
  Exchange.set_mark ex btc (px "800");
  Exchange.reopen ex;
  let original = Exchange.drain_guard_events ex in
  let replayed = Exchange.create () in
  Queue.iter inputs ~f:(fun input ->
    let buf = Binable.to_bigstring (module Input) input in
    Exchange.apply replayed (Binable.of_bigstring (module Input) buf));
  print_s
    [%sexp
      (List.length original : int)
      , (List.equal Guard_event.equal original (Exchange.drain_guard_events replayed)
         : bool)];
  print_s
    [%sexp
      (Exchange.set_halt_rule ex (Some { (rule ()) with levels = [] }) |> Result.is_error
       : bool)];
  [%expect {|
    (12 true)
    true
    |}]
;;
