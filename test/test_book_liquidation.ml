open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

let liquidator = Account.of_string "0xliquidator"
let config = Book_liquidation.Config.create ~liquidator

let short a =
  if Account.equal a liquidator
  then "liq"
  else Account.to_string a |> Fn.flip String.drop_prefix 38
;;

let fresh ?(record = ignore) () =
  let ex = Exchange.create ~book_liquidation:config () in
  Exchange.record_inputs ex ~f:record;
  List.iter [ 1; 2; 3 ] ~f:(fun n -> Exchange.deposit ex (acct n) (usd "1000000"));
  ex
;;

let place ex n side p s =
  ignore
    (Exchange.place ex (acct n) (Order_request.limit btc side ~px:(px p) ~size:(sz s))
     : Order_status.t)
;;

(* Account [n] deposits [balance] and buys [size] from account 3 at 100000. *)
let long ex n ~balance ~size =
  Exchange.deposit ex (acct n) (usd balance);
  ignore (Exchange.set_leverage ex (acct n) btc 40 : unit Or_error.t);
  place ex 3 Sell "100000" size;
  place ex n Buy "100000" size;
  ignore (Exchange.drain_events ex : Event.t list)
;;

let print_events ex =
  let liquidations = Exchange.drain_liquidation_events ex in
  let events = Exchange.drain_numbered_events ex in
  let show_liquidation (l : Book_liquidation.Event.t) =
    printf
      !"liquidation %{sexp: Book_liquidation.Method.t} %s oid=%{sexp: Order_id.t option} \
        size=%s order=%s mark=%s equity=%s ntl=%s\n"
      l.method_
      (short l.account)
      l.order_id
      (Size.to_string l.size)
      (Size.to_string l.order_size)
      (Price.to_string l.mark)
      (Usd.to_string l.equity)
      (Usd.to_string l.notional)
  in
  let show_event (e : Event.t) =
    match e with
    | Fill { fill; _ } ->
      printf
        "fill %s@%s taker=%s maker=%s\n"
        (Size.to_string fill.sz)
        (Price.to_string fill.px)
        (short fill.taker)
        (short fill.maker)
    | Liquidation { liquidation = l; _ } ->
      printf
        "taken over %s %s@%s pnl %s\n"
        (short l.account)
        (Size.to_string l.size)
        (Price.to_string l.px)
        (Usd.to_string l.pnl)
    | Order_cancelled { account; order; reason; _ } ->
      printf
        !"cancelled %s oid=%s %{sexp: Event.Cancel_reason.t}\n"
        (short account)
        (Order_id.to_string order.order_id)
        reason
    | Order_rejected { account; order_id; reason; _ } ->
      printf
        !"rejected %s oid=%{sexp: Order_id.t option} %{sexp: Reject_reason.t}\n"
        (short account)
        order_id
        reason
    | Order_filled { account; order; _ } ->
      printf "filled %s oid=%s\n" (short account) (Order_id.to_string order.order_id)
    | Order_accepted _ | Funding _ -> ()
  in
  let rec loop (ls : Book_liquidation.Event.t list) (es : Event.Numbered.t list) =
    match ls, es with
    | [], [] -> ()
    | l :: ls, e :: _ when l.before_seq <= e.seq ->
      show_liquidation l;
      loop ls es
    | l :: ls, [] ->
      show_liquidation l;
      loop ls []
    | _, e :: es ->
      show_event e.event;
      loop ls es
  in
  loop liquidations events
;;

let show_account ex n =
  let v = Exchange.account_view ex n in
  print_s
    [%message
      ""
        ~account:(short n : string)
        ~balance:(v.balance : Usd.t)
        ~equity:(v.equity : Usd.t)
        ~positions:
          (List.map v.positions ~f:(fun p -> p.symbol, p.size, p.entry_px)
           : (Symbol.t * Size.t * Price.t) list)]
;;

let%expect_test "a market order to the book closes the position; the rest stays" =
  let ex = fresh () in
  long ex 4 ~balance:"60" ~size:"0.01";
  place ex 4 Buy "90000" "0.0002";
  place ex 2 Buy "95000" "0.02";
  ignore (Exchange.drain_events ex : Event.t list);
  (* Maintenance is 1/80 of the notional: below it near 95300, below two thirds of it
     near 94900. *)
  Exchange.set_mark ex btc (px "95400");
  print_events ex;
  [%expect {| |}];
  Exchange.set_mark ex btc (px "95100");
  print_events ex;
  show_account ex (acct 4);
  [%expect
    {|
    cancelled 0004 oid=3 Liquidated
    liquidation Market 0004 oid=(5) size=0.01 order=0.01 mark=95100 equity=10.65 ntl=951
    fill 0.01@95000 taker=0004 maker=0002
    filled 0004 oid=5
    ((account 0004) (balance 9.3175) (equity 9.3175) (positions ()))
    |}]
;;

let%expect_test "the backstop takes over below two thirds of maintenance" =
  let ex = fresh () in
  long ex 4 ~balance:"60" ~size:"0.01";
  Exchange.set_mark ex btc (px "94000");
  print_events ex;
  show_account ex (acct 4);
  show_account ex liquidator;
  [%expect
    {|
    liquidation Backstop 0004 oid=() size=0.01 order=0.01 mark=94000 equity=-0.35 ntl=940
    taken over 0004 0.01@94000 pnl -60
    ((account 0004) (balance 0) (equity 0) (positions ()))
    ((account liq) (balance -0.35) (equity -0.35) (positions ((BTC 0.01 94000))))
    |}]
;;

let%expect_test "an order the book cannot absorb leaves the position to the backstop" =
  let ex = fresh () in
  long ex 4 ~balance:"60" ~size:"0.01";
  Exchange.set_mark ex btc (px "95100");
  print_events ex;
  [%expect
    {|
    liquidation Market 0004 oid=(3) size=0.01 order=0.01 mark=95100 equity=10.65 ntl=951
    rejected 0004 oid=(3) No_liquidity
    |}];
  Exchange.set_mark ex btc (px "94800");
  print_events ex;
  show_account ex (acct 4);
  [%expect
    {|
    liquidation Backstop 0004 oid=() size=0.01 order=0.01 mark=94800 equity=7.65 ntl=948
    taken over 0004 0.01@94800 pnl -52
    ((account 0004) (balance 0) (equity 0) (positions ()))
    |}]
;;

let%expect_test "large positions are liquidated in slices, then in full during the \
                 cooldown"
  =
  let ex = fresh () in
  long ex 4 ~balance:"5000" ~size:"1.2";
  place ex 2 Buy "96900" "2";
  ignore (Exchange.drain_events ex : Event.t list);
  Exchange.step ex ~now:1_000_000_000;
  Exchange.set_mark ex btc (px "97000");
  print_events ex;
  show_account ex (acct 4);
  [%expect
    {|
    liquidation Market 0004 oid=(4) size=1.2 order=0.24 mark=97000 equity=1358 ntl=116400
    fill 0.24@96900 taker=0004 maker=0002
    filled 0004 oid=4
    ((account 0004) (balance 4205.8604) (equity 1325.8604)
     (positions ((BTC 0.96 100000))))
    |}];
  (* Below maintenance again within 30 s: the whole position goes. *)
  Exchange.step ex ~now:2_000_000_000;
  Exchange.set_mark ex btc (px "96700");
  print_events ex;
  show_account ex (acct 4);
  [%expect
    {|
    liquidation Market 0004 oid=(5) size=0.96 order=0.96 mark=96700 equity=1037.8604 ntl=92832
    fill 0.96@96900 taker=0004 maker=0002
    filled 0004 oid=5
    ((account 0004) (balance 1197.302) (equity 1197.302) (positions ()))
    |}]
;;

let%expect_test "journals record book liquidation and replay it" =
  let inputs = Queue.create () in
  let ex = fresh ~record:(Queue.enqueue inputs) () in
  let header = Journal.Header.of_exchange ex in
  long ex 4 ~balance:"60" ~size:"0.01";
  place ex 2 Buy "95000" "0.005";
  Exchange.set_mark ex btc (px "95100");
  Exchange.set_mark ex btc (px "94000");
  let s = Journal.to_string ~header (Queue.to_list inputs) in
  let header', inputs' = Journal.of_string_with_header s |> ok_exn in
  print_s
    [%message
      ""
        ~magic:(String.prefix s 8 : string)
        ~same_header:(Journal.Header.equal header header' : bool)];
  let replayed = Journal.replay ~header:header' inputs' in
  let state ex =
    ( List.map
        (Exchange.drain_liquidation_events ex)
        ~f:[%sexp_of: Book_liquidation.Event.t]
    , List.map
        [ acct 2; acct 4; liquidator ]
        ~f:(fun a -> [%sexp (Exchange.account_view ex a : Account_view.t)]) )
  in
  print_s
    [%message
      ""
        ~identical:
          ([%equal: Sexp.t list * Sexp.t list] (state ex) (state replayed) : bool)];
  [%expect {|
    ((magic EXJRNL03) (same_header true))
    (identical true)
    |}]
;;
