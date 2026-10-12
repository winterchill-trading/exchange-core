open! Core
open! Exchange_core
open Helpers

let%expect_test "price and size rules" =
  let tick =
    Instrument.create btc ~size_decimals:3 ~price_tick:(px "0.5") ~max_leverage:10
  in
  let sig5 =
    Instrument.create
      btc
      ~size_decimals:5
      ~price_tick:(px "0.1")
      ~max_significant_figures:5
      ~max_leverage:40
  in
  let show (i : Instrument.t) =
    List.iter [ "100"; "100.5"; "100.25"; "12345.6"; "123456"; "0"; "-1" ] ~f:(fun p ->
      printf "%s:%b " p (Instrument.valid_price i (px p)));
    print_endline "";
    List.iter [ 101.26; 101.74; 12345.67; 99999.95 ] ~f:(fun x ->
      printf "%g->%s " x (Price.to_string (Instrument.round_price i x)));
    print_endline "";
    List.iter [ "0.001"; "0.0015"; "1" ] ~f:(fun s ->
      printf "%s:%b " s (Instrument.valid_size i (sz s)));
    print_endline (Size.to_string (Instrument.lot_size i))
  in
  show tick;
  show sig5;
  [%expect
    {|
    100:true 100.5:true 100.25:false 12345.6:false 123456:true 0:false -1:false
    101.26->101.5 101.74->101.5 12345.7->12345.5 99999.9->100000
    0.001:true 0.0015:false 1:true 0.001
    100:true 100.5:true 100.25:false 12345.6:false 123456:true 0:false -1:false
    101.26->101.3 101.74->101.7 12345.7->12346 99999.9->100000
    0.001:true 0.0015:true 1:true 0.00001
    |}]
;;
