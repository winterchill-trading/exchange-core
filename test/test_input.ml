open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

let samples : Input.t list =
  let a = acct 1 in
  let req = Order_request.limit btc Buy ~px:(px "100000.5") ~size:(sz "0.01") in
  [ Deposit { account = a; usd = usd "1234.5" }
  ; Set_leverage { account = a; symbol = btc; leverage = 10 }
  ; Place { account = a; request = req }
  ; Place
      { account = a
      ; request =
          Order_request.market
            ~slippage_bps:50
            ~reduce_only:true
            ~client_order_id:(Client_order_id.of_string "c1")
            btc
            Sell
            ~size:(sz "1")
      }
  ; Reject
      { account = a
      ; symbol = Some btc
      ; order_id = Some (Order_id.of_int 7)
      ; client_order_id = None
      ; reason =
          Post_only_would_cross { best_bid = Some (px "99999.9"); best_ask = None }
      }
  ; Reject
      { account = a
      ; symbol = None
      ; order_id = None
      ; client_order_id = None
      ; reason = Below_min_value { min = usd "10" }
      }
  ; Cancel { account = a; symbol = btc; order_id = Order_id.of_int 3 }
  ; Cancel_by_client_order_id
      { account = a; symbol = btc; client_order_id = Client_order_id.of_string "c1" }
  ; Modify
      { account = a
      ; target = Client_order_id (Client_order_id.of_string "c1")
      ; request = req
      }
  ; Modify { account = a; target = Order_id (Order_id.of_int 9); request = req }
  ; Set_mark { symbol = btc; px = px "101000" }
  ; Set_funding_rate { symbol = btc; rate = 0.0001 }
  ; Step { now = 3_600_000_000_000 }
  ]
;;

let%expect_test "bin_prot round trip" =
  List.iter samples ~f:(fun input ->
    let buf = Binable.to_bigstring (module Input) input in
    let back = Binable.of_bigstring (module Input) buf in
    if not (Input.equal input back)
    then print_s [%message "mismatch" (input : Input.t) (back : Input.t)];
    let name =
      match Input.sexp_of_t input with
      | List (Atom name :: _) -> name
      | sexp -> Sexp.to_string sexp
    in
    printf "%-26s %3d bytes\n" name (Bigstring.length buf));
  [%expect {|
    Deposit                     53 bytes
    Set_leverage                49 bytes
    Place                       68 bytes
    Place                       63 bytes
    Reject                      64 bytes
    Reject                      53 bytes
    Cancel                      49 bytes
    Cancel_by_client_order_id   51 bytes
    Modify                      72 bytes
    Modify                      70 bytes
    Set_mark                    14 bytes
    Set_funding_rate            13 bytes
    Step                        10 bytes
    |}]
;;
