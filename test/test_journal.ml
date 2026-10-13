open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

let ns_per_tick = 100_000_000

(* A seeded market simulation plus one scripted account exercising every kind of input,
   run across a funding boundary. Returns every event, oldest first. *)
let run exchange =
  let events = Queue.create () in
  let drain () = Queue.enqueue_all events (Exchange.drain_events exchange) in
  let sim =
    Market_sim.create
      { Market_sim.Config.default with seed = 11; noise_traders = 4 }
      exchange
  in
  let me = acct 1 in
  let cid = Client_order_id.of_string "mine" in
  Exchange.deposit exchange me (usd "50000");
  ignore (Exchange.set_leverage exchange me btc 10 : unit Or_error.t);
  ignore (Exchange.set_leverage exchange me btc 1000 : unit Or_error.t);
  Exchange.set_funding_rate exchange btc 0.0001;
  for i = 1 to 400 do
    Market_sim.tick sim;
    (match i % 50 with
     | 1 ->
       let px = Option.value_exn (Market_sim.reference_price sim btc) in
       let px = Price.( - ) px (Price.of_int 20) in
       ignore
         (Exchange.place
            exchange
            me
            (Order_request.limit ~client_order_id:cid btc Buy ~px ~size:(sz "0.01"))
          : Order_status.t)
     | 11 ->
       let px = Option.value_exn (Market_sim.reference_price sim btc) in
       ignore
         (Exchange.modify
            exchange
            me
            (Client_order_id cid)
            (Order_request.limit ~client_order_id:cid btc Buy ~px ~size:(sz "0.02"))
          : Order_status.t)
     | 21 ->
       ignore
         (Exchange.cancel_by_client_order_id exchange me ~symbol:btc cid
          : Cancel_status.t)
     | 31 ->
       ignore
         (Exchange.place exchange me (Order_request.market btc Sell ~size:(sz "0.005"))
          : Order_status.t)
     | 41 ->
       ignore
         (Exchange.reject exchange me ~symbol:btc (Unsupported "stop orders")
          : Order_status.t);
       ignore
         (Exchange.cancel exchange me ~symbol:btc (Order_id.of_int 1) : Cancel_status.t)
     | _ -> ());
    Exchange.step exchange ~now:(i * ns_per_tick * 100);
    drain ()
  done;
  Queue.to_list events
;;

let event_sexps events = List.map events ~f:Event.sexp_of_t

let%expect_test "a journal replays into the same event stream" =
  let path = "test_journal.bin" in
  let original = Exchange.create () in
  let journal = Journal.create path in
  Journal.attach journal original;
  let events = run original in
  Journal.close journal;
  let inputs = Journal.load path |> ok_exn in
  let size = In_channel.read_all path |> String.length in
  Stdlib.Sys.remove path;
  let replayed = Journal.replay inputs in
  let replayed_events = Exchange.drain_events replayed in
  let kinds =
    List.map inputs ~f:(fun input ->
      match Input.sexp_of_t input with
      | List (Atom name :: _) -> name
      | sexp -> Sexp.to_string sexp)
    |> List.sort_and_group ~compare:String.compare
    |> List.map ~f:(fun group -> List.hd_exn group, List.length group)
  in
  print_s
    [%message
      ""
        ~inputs:(Journal.length journal : int)
        ~loaded:(List.length inputs : int)
        ~bytes:(size : int)
        (kinds : (string * int) list)
        ~events:(List.length events : int)
        ~replayed_events:(List.length replayed_events : int)
        ~identical:
          ([%equal: Sexp.t list] (event_sexps events) (event_sexps replayed_events)
           : bool)];
  [%expect
    {|
    ((inputs 4498) (loaded 4498) (bytes 194561)
     (kinds
      ((Cancel 1288) (Cancel_by_client_order_id 8) (Deposit 5) (Modify 8)
       (Place 1578) (Reject 8) (Set_funding_rate 1) (Set_leverage 2)
       (Set_mark 1200) (Step 400)))
     (events 3149) (replayed_events 3149) (identical true))
    |}];
  (* The replayed exchange ends in the same state too. *)
  let state ex =
    [%sexp
      (Exchange.account_view ex (acct 1) : Account_view.t)
      , (Exchange.l2 ex btc : L2.t option)
      , (Exchange.now ex : int)]
  in
  print_s [%sexp (Sexp.equal (state original) (state replayed) : bool)];
  [%expect {| true |}]
;;

let%expect_test "a different config diverges" =
  let original = Exchange.create () in
  let inputs = Queue.create () in
  Exchange.record_inputs original ~f:(Queue.enqueue inputs);
  let events = run original in
  let config = { Exchange.Config.default with min_order_value = usd "500" } in
  let replayed = Journal.replay ~config (Queue.to_list inputs) in
  let replayed_events = Exchange.drain_events replayed in
  let first_difference =
    List.zip_with_remainder (event_sexps events) (event_sexps replayed_events)
    |> fst
    |> List.findi ~f:(fun _ (a, b) -> not (Sexp.equal a b))
    |> Option.map ~f:fst
  in
  print_s [%message (first_difference : int option)];
  [%expect {| (first_difference (2)) |}]
;;

let%expect_test "truncated and foreign files are errors" =
  let s = Journal.to_string [ Step { now = 1 }; Step { now = 2 } ] in
  print_s [%sexp (Journal.of_string s : Input.t list Or_error.t)];
  [%expect {| (Ok ((Step (now 1)) (Step (now 2)))) |}];
  print_s [%sexp (Journal.of_string (String.drop_suffix s 1) : Input.t list Or_error.t)];
  [%expect
    {|
    (Error
     ("Journal: unreadable record" (offset 10) (records_read 1)
      (exn (Bin_prot__Common.Buffer_short))))
    |}];
  print_s [%sexp (Journal.of_string "hello" : Input.t list Or_error.t)];
  [%expect {| (Error "Journal: missing magic string") |}]
;;

let%expect_test "the self-trade policy travels in the header" =
  let path = "test_journal_stp.bin" in
  let self_trade : Order_book.Stp.t = Expire_maker in
  let original = Exchange.create ~self_trade () in
  let journal = Journal.create ~header:{ self_trade } path in
  Journal.attach journal original;
  let events = run original in
  Journal.close journal;
  let contents = In_channel.read_all path in
  Stdlib.Sys.remove path;
  let header, inputs = Journal.of_string_with_header contents |> ok_exn in
  let replay ?header () = Exchange.drain_events (Journal.replay ?header inputs) in
  let identical replayed =
    [%equal: Sexp.t list] (event_sexps events) (event_sexps replayed)
  in
  let self_trade_cancels =
    List.count events ~f:(function
      | Order_cancelled { reason = Self_trade; _ } -> true
      | _ -> false)
  in
  print_s
    [%message
      ""
        ~magic:(String.prefix contents 8 : string)
        (header : Journal.Header.t)
        (self_trade_cancels : int)
        ~with_header:(identical (replay ~header ()) : bool)
        ~without_header:(identical (replay ()) : bool)];
  [%expect
    {|
    ((magic EXJRNL02) (header ((self_trade Expire_maker)))
     (self_trade_cancels 67) (with_header true) (without_header false))
    |}]
;;

let%expect_test "default headers keep the original format" =
  let inputs : Input.t list = [ Step { now = 1 } ] in
  let plain = Journal.to_string inputs in
  print_s
    [%message
      ""
        ~same_bytes:
          (String.equal plain (Journal.to_string ~header:Journal.Header.default inputs)
           : bool)
        ~magic:(String.prefix plain 8 : string)
        ~expire_maker:
          (Journal.of_string_with_header
             (Journal.to_string ~header:{ self_trade = Expire_maker } inputs)
           : (Journal.Header.t * Input.t list) Or_error.t)
        ~bad_header:
          (Journal.of_string_with_header (Journal.magic_with_header ^ "\255")
           : (Journal.Header.t * Input.t list) Or_error.t)];
  [%expect
    {|
    ((same_bytes true) (magic EXJRNL01)
     (expire_maker (Ok (((self_trade Expire_maker)) ((Step (now 1))))))
     (bad_header
      (Error
       ("Journal: unreadable header"
        (exn
         (src/common.ml.Read_error
          "Sum_tag / exchange-core/engine/journal.ml.Header.Wire.stp" 9))))))
    |}];
  let path = "test_journal_mismatch.bin" in
  let journal = Journal.create ~header:{ self_trade = Cancel_both } path in
  (match Journal.attach journal (Exchange.create ()) with
   | () -> print_endline "attached"
   | exception exn -> print_s [%sexp (exn : exn)]);
  Journal.close journal;
  Stdlib.Sys.remove path;
  [%expect
    {|
    ("Journal.attach: the exchange's self-trade policy differs from the header"
     (self_trade Cancel_taker) (t.header ((self_trade Cancel_both))))
    |}]
;;
