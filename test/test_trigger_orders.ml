open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

let short a = Account.to_string a |> Fn.flip String.drop_prefix 38

let fresh () =
  let ex = Exchange.create () in
  List.iter [ 1; 2; 3 ] ~f:(fun n -> Exchange.deposit ex (acct n) (usd "10000"));
  ex
;;

let limit ?(tif = Tif.Gtc) ?reduce_only ?cid side p s =
  Order_request.limit
    ~tif
    ?reduce_only
    ?client_order_id:(Option.map cid ~f:Client_order_id.of_string)
    btc
    side
    ~px:(px p)
    ~size:(sz s)
;;

let market ?reduce_only ?cid side s =
  Order_request.market
    ~slippage_bps:1000
    ?reduce_only
    ?client_order_id:(Option.map cid ~f:Client_order_id.of_string)
    btc
    side
    ~size:(sz s)
;;

let trigger kind p = { Trigger.trigger_px = px p; kind }

let place_trigger ex n req kind p =
  let _oid, status = Exchange.place_trigger ex (acct n) req (trigger kind p) in
  print_s [%sexp (status : Order_status.t)]
;;

let summarize_event (e : Event.t) =
  match e with
  | Order_accepted { account; order; _ } ->
    sprintf
      "accepted %s oid=%s %s@%s"
      (short account)
      (Order_id.to_string order.order_id)
      (Size.to_string order.size)
      (Price.to_string order.px)
  | Order_rejected { account; order_id; reason; _ } ->
    sprintf
      !"rejected %s oid=%{sexp: Order_id.t option} %{sexp: Reject_reason.t}"
      (short account)
      order_id
      reason
  | Order_filled { account; order; _ } ->
    sprintf "filled %s oid=%s" (short account) (Order_id.to_string order.order_id)
  | Order_cancelled { account; order; reason; _ } ->
    sprintf
      !"cancelled %s oid=%s %{sexp: Event.Cancel_reason.t}"
      (short account)
      (Order_id.to_string order.order_id)
      reason
  | Fill { fill; _ } ->
    sprintf
      "fill %s@%s taker=%s maker=%s"
      (Size.to_string fill.sz)
      (Price.to_string fill.px)
      (short fill.taker)
      (short fill.maker)
  | Liquidation { liquidation = l; _ } ->
    sprintf "liquidation %s %s" (short l.account) (Size.to_string l.size)
  | Funding _ -> "funding"
;;

let summarize_trigger (e : Trigger_event.t) =
  sprintf
    !"trigger %{sexp: Trigger_event.Kind.t} %s oid=%s %{sexp: Side.t} %s %{sexp: \
      Trigger.Kind.t}@%s"
    e.kind
    (short e.order.account)
    (Order_id.to_string e.order.order_id)
    e.order.request.side
    (Size.to_string e.order.request.size)
    e.order.trigger.kind
    (Price.to_string e.order.trigger.trigger_px)
;;

(* Both logs in the order they happened, using [before_seq]. *)
let print_events ex =
  let triggers = Exchange.drain_trigger_events ex in
  let events = Exchange.drain_numbered_events ex in
  let rec loop (triggers : Trigger_event.t list) (events : Event.Numbered.t list) =
    match triggers, events with
    | [], [] -> ()
    | t :: ts, e :: _ when t.before_seq <= e.seq ->
      print_endline (summarize_trigger t);
      loop ts events
    | t :: ts, [] ->
      print_endline (summarize_trigger t);
      loop ts []
    | _, e :: es ->
      print_endline (summarize_event e.event);
      loop triggers es
  in
  loop triggers events
;;

(* Account 1 goes long 0.01 BTC at 100000 from account 2; account 3 bids below. *)
let long_with_bids () =
  let ex = fresh () in
  ignore (Exchange.place ex (acct 2) (limit Sell "100000" "0.01") : Order_status.t);
  ignore (Exchange.place ex (acct 1) (limit Buy "100000" "0.01") : Order_status.t);
  ignore (Exchange.place ex (acct 3) (limit Buy "99000" "0.02") : Order_status.t);
  Exchange.set_mark ex btc (px "100000");
  ignore (Exchange.drain_events ex : Event.t list);
  ex
;;

let%expect_test "a market stop-loss fires when the mark falls to it" =
  let ex = long_with_bids () in
  place_trigger ex 1 (market ~reduce_only:true Sell "0.01") Stop_loss "99500";
  print_s
    [%sexp
      (Exchange.trigger_orders ex (acct 1) |> List.map ~f:Trigger_order.open_order
       : Open_order.t list)];
  Exchange.set_mark ex btc (px "99600");
  print_events ex;
  [%expect
    {|
    (Resting (order_id 4) (client_order_id ()))
    (((symbol BTC) (side Sell) (px 99500) (size 0.01) (orig_size (0.01))
      (order_id 4) (client_order_id ()) (timestamp 0)))
    trigger Placed 0001 oid=4 Sell 0.01 Stop_loss@99500
    |}];
  Exchange.set_mark ex btc (px "99500");
  print_events ex;
  print_s [%sexp (Exchange.trigger_orders ex (acct 1) : Trigger_order.t list)];
  print_s [%sexp ((Exchange.account_view ex (acct 1)).positions : Position_view.t list)];
  [%expect
    {|
    trigger Triggered 0001 oid=4 Sell 0.01 Stop_loss@99500
    fill 0.01@99000 taker=0001 maker=0003
    filled 0001 oid=4
    ()
    ()
    |}]
;;

let%expect_test "limit triggers, take-profits on both sides and immediate firing" =
  let ex = long_with_bids () in
  (* A take-profit sell fires at or above its price; resting at its limit. *)
  place_trigger ex 1 (limit ~reduce_only:true Sell "101000" "0.005") Take_profit "100800";
  (* A buy stop opening a position fires at or above its price. *)
  place_trigger ex 3 (limit Buy "101500" "0.001") Stop_loss "100900";
  (* Already reached by the mark: fires at once. *)
  place_trigger ex 2 (limit Sell "100500" "0.001") Take_profit "99000";
  print_events ex;
  [%expect
    {|
    (Resting (order_id 4) (client_order_id ()))
    (Resting (order_id 5) (client_order_id ()))
    (Resting (order_id 6) (client_order_id ()))
    trigger Placed 0001 oid=4 Sell 0.005 Take_profit@100800
    trigger Placed 0003 oid=5 Buy 0.001 Stop_loss@100900
    trigger Placed 0002 oid=6 Sell 0.001 Take_profit@99000
    trigger Triggered 0002 oid=6 Sell 0.001 Take_profit@99000
    accepted 0002 oid=6 0.001@100500
    |}];
  Exchange.step ex ~now:1_000;
  Exchange.set_mark ex btc (px "100850");
  print_events ex;
  [%expect
    {|
    trigger Triggered 0001 oid=4 Sell 0.005 Take_profit@100800
    accepted 0001 oid=4 0.005@101000
    |}];
  Exchange.set_mark ex btc (px "101000");
  print_events ex;
  print_s [%sexp (Exchange.open_orders ex (acct 3) : Open_order.t list)];
  [%expect
    {|
    trigger Triggered 0003 oid=5 Buy 0.001 Stop_loss@100900
    fill 0.001@100500 taker=0003 maker=0002
    filled 0002 oid=6
    filled 0003 oid=5
    (((symbol BTC) (side Buy) (px 99000) (size 0.02) (orig_size (0.02))
      (order_id 3) (client_order_id ()) (timestamp 0)))
    |}]
;;

let%expect_test "rejections at placement and when firing" =
  let ex = long_with_bids () in
  (* Off tick trigger price, limit price missing, size off the lot, below $10. *)
  place_trigger ex 1 (market Sell "0.01") Stop_loss "99500.05";
  place_trigger ex 1 { (limit Sell "99000" "0.01") with px = None } Stop_loss "99500";
  place_trigger ex 1 (market Sell "0.000001") Stop_loss "99500";
  place_trigger ex 1 (market Sell "0.0001") Stop_loss "99500";
  (* A client order id in use by a trigger order. *)
  place_trigger ex 1 (market ~cid:"x" Sell "0.001") Stop_loss "99500";
  place_trigger ex 1 (market ~cid:"x" Sell "0.001") Stop_loss "99400";
  print_events ex;
  [%expect
    {|
    (Rejected Invalid_price)
    (Rejected Invalid_price)
    (Rejected Invalid_size)
    (Rejected (Below_min_value (min 10)))
    (Resting (order_id 8) (client_order_id (x)))
    (Rejected Duplicate_client_order_id)
    rejected 0001 oid=(4) Invalid_price
    rejected 0001 oid=(5) Invalid_price
    rejected 0001 oid=(6) Invalid_size
    rejected 0001 oid=(7) (Below_min_value (min 10))
    trigger Placed 0001 oid=8 Sell 0.001 Stop_loss@99500
    rejected 0001 oid=(9) Duplicate_client_order_id
    |}];
  (* Reduce-only with nothing left to reduce is rejected when it fires, under its id. *)
  place_trigger ex 3 (limit ~reduce_only:true Buy "100200" "0.01") Stop_loss "100100";
  Exchange.set_mark ex btc (px "100200");
  print_events ex;
  [%expect
    {|
    (Resting (order_id 10) (client_order_id ()))
    trigger Placed 0003 oid=10 Buy 0.01 Stop_loss@100100
    trigger Triggered 0003 oid=10 Buy 0.01 Stop_loss@100100
    rejected 0003 oid=(10) Reduce_only_would_increase
    |}]
;;

let%expect_test "cancel, cancel by client order id, modify and liquidation" =
  let ex = long_with_bids () in
  place_trigger ex 1 (market ~reduce_only:true Sell "0.01") Stop_loss "99500";
  place_trigger ex 1 (market ~cid:"tp" ~reduce_only:true Sell "0.01") Take_profit "101000";
  print_s
    [%sexp
      (Exchange.cancel ex (acct 1) ~symbol:btc (Order_id.of_int 4) : Cancel_status.t)];
  (* Only the owner can cancel. *)
  print_s
    [%sexp
      (Exchange.cancel_by_client_order_id
         ex
         (acct 2)
         ~symbol:btc
         (Client_order_id.of_string "tp")
       : Cancel_status.t)];
  print_s
    [%sexp
      (Exchange.cancel_by_client_order_id
         ex
         (acct 1)
         ~symbol:btc
         (Client_order_id.of_string "tp")
       : Cancel_status.t)];
  print_events ex;
  [%expect
    {|
    (Resting (order_id 4) (client_order_id ()))
    (Resting (order_id 5) (client_order_id (tp)))
    Cancelled
    Not_found
    Cancelled
    trigger Placed 0001 oid=4 Sell 0.01 Stop_loss@99500
    trigger Placed 0001 oid=5 Sell 0.01 Take_profit@101000
    trigger (Cancelled User) 0001 oid=4 Sell 0.01 Stop_loss@99500
    trigger (Cancelled User) 0001 oid=5 Sell 0.01 Take_profit@101000
    |}];
  (* Modify a trigger order into another trigger order, then into a limit order. *)
  place_trigger ex 1 (market ~reduce_only:true Sell "0.01") Stop_loss "99500";
  print_s
    [%sexp
      (Exchange.modify
         ~trigger:(trigger Stop_loss "99300")
         ex
         (acct 1)
         (Order_id (Order_id.of_int 6))
         (market ~reduce_only:true Sell "0.01")
       : Order_status.t)];
  print_s
    [%sexp
      (Exchange.modify
         ex
         (acct 1)
         (Order_id (Order_id.of_int 7))
         (limit Sell "102000" "0.01")
       : Order_status.t)];
  print_events ex;
  [%expect
    {|
    (Resting (order_id 6) (client_order_id ()))
    (Resting (order_id 7) (client_order_id ()))
    (Resting (order_id 8) (client_order_id ()))
    trigger Placed 0001 oid=6 Sell 0.01 Stop_loss@99500
    trigger (Cancelled Modified) 0001 oid=6 Sell 0.01 Stop_loss@99500
    trigger Placed 0001 oid=7 Sell 0.01 Stop_loss@99300
    trigger (Cancelled Modified) 0001 oid=7 Sell 0.01 Stop_loss@99300
    accepted 0001 oid=8 0.01@102000
    |}];
  (* A liquidated account loses its trigger orders. *)
  Exchange.deposit ex (acct 4) (usd "60");
  ignore (Exchange.place ex (acct 2) (limit Sell "100000" "0.01") : Order_status.t);
  ignore (Exchange.place ex (acct 4) (limit Buy "100000" "0.01") : Order_status.t);
  place_trigger ex 4 (market ~reduce_only:true Sell "0.01") Stop_loss "90000";
  ignore (Exchange.drain_events ex : Event.t list);
  ignore (Exchange.drain_trigger_events ex : Trigger_event.t list);
  Exchange.set_mark ex btc (px "94500");
  print_events ex;
  print_s [%sexp (Exchange.trigger_orders ex (acct 4) : Trigger_order.t list)];
  [%expect
    {|
    (Resting (order_id 11) (client_order_id ()))
    liquidation 0004 0.01
    trigger (Cancelled Liquidated) 0004 oid=11 Sell 0.01 Stop_loss@90000
    ()
    |}]
;;

let%expect_test "a journal of trigger orders replays into the same events" =
  let ex = long_with_bids () in
  let inputs = Queue.create () in
  Exchange.record_inputs ex ~f:(Queue.enqueue inputs);
  place_trigger ex 1 (market ~reduce_only:true Sell "0.01") Stop_loss "99500";
  place_trigger ex 3 (limit Buy "101500" "0.001") Stop_loss "100900";
  ignore
    (Exchange.modify
       ~trigger:(trigger Stop_loss "100950")
       ex
       (acct 3)
       (Order_id (Order_id.of_int 5))
       (limit Buy "101500" "0.002")
     : Order_status.t);
  Exchange.set_mark ex btc (px "101000");
  Exchange.step ex ~now:1_000_000;
  Exchange.set_mark ex btc (px "99400");
  [%expect
    {|
    (Resting (order_id 4) (client_order_id ()))
    (Resting (order_id 5) (client_order_id ()))
    |}];
  let sexps ex =
    ( List.map (Exchange.drain_trigger_events ex) ~f:[%sexp_of: Trigger_event.t]
    , List.map (Exchange.drain_events ex) ~f:[%sexp_of: Event.t] )
  in
  let original = sexps ex in
  (* Replay everything after [long_with_bids] on a copy of its state. *)
  let copy = long_with_bids () in
  let s = Journal.to_string (Queue.to_list inputs) in
  List.iter (Journal.of_string s |> ok_exn) ~f:(Exchange.apply copy);
  let replayed = sexps copy in
  print_s
    [%message
      ""
        ~inputs:(Queue.length inputs : int)
        ~trigger_events:(List.length (fst original) : int)
        ~events:(List.length (snd original) : int)
        ~identical:([%equal: Sexp.t list * Sexp.t list] original replayed : bool)];
  [%expect {| ((inputs 6) (trigger_events 6) (events 5) (identical true)) |}]
;;
