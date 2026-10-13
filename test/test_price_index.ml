open! Core
open! Exchange_core_engine

let sec n = n * 1_000_000_000

let%expect_test "median" =
  List.iter
    [ []; [ 3. ]; [ 3.; 1. ]; [ 5.; 1.; 3. ]; [ 4.; 1.; 3.; 2. ] ]
    ~f:(fun xs -> print_s [%sexp (Price_index.median xs : float option)]);
  [%expect {|
    ()
    (3)
    (2)
    (3)
    (2.5)
    |}]
;;

let%expect_test "the moving average weights samples by the time they stood" =
  let ema = Price_index.Ema.create ~tau:(Time_ns.Span.of_int_sec 150) in
  print_s [%sexp (Price_index.Ema.value ema : float option)];
  Price_index.Ema.update ema ~sample:10. ~dt:Time_ns.Span.zero;
  print_s [%sexp (Price_index.Ema.value ema : float option)];
  Price_index.Ema.update ema ~sample:20. ~dt:(Time_ns.Span.of_int_sec 3);
  Price_index.Ema.update ema ~sample:0. ~dt:(Time_ns.Span.of_int_sec 3);
  printf "%.4f\n" (Option.value_exn (Price_index.Ema.value ema));
  [%expect {|
    ()
    (10)
    9.9000
    |}]
;;

let%expect_test "mark from the oracle and the book" =
  let t = Price_index.create () in
  let update ~now ~oracle ?mid ?bid ?ask ?last () =
    let mark =
      Price_index.update t ~now ~oracle ~mid ~best_bid:bid ~best_ask:ask ~last_trade:last
    in
    printf "oracle %.1f -> mark %.4f\n" oracle mark
  in
  (* No book: the oracle. *)
  update ~now:(sec 0) ~oracle:100. ();
  (* The book sits 1 above the oracle: both inputs and the 30 s average agree. *)
  update ~now:(sec 3) ~oracle:100. ~mid:101. ~bid:100.9 ~ask:101.1 ~last:101. ();
  (* The oracle jumps: the oracle-based input moves towards it, but the book and its 30 s
     average stay, so the mark stays with the book. *)
  update ~now:(sec 6) ~oracle:105. ~mid:101. ~bid:100.9 ~ask:101.1 ~last:101. ();
  (* The book follows a minute later. *)
  update ~now:(sec 66) ~oracle:105. ~mid:105.5 ~bid:105.4 ~ask:105.6 ~last:105.5 ();
  print_s [%sexp (Price_index.oracle t : float option)];
  [%expect
    {|
    oracle 100.0 -> mark 100.0000
    oracle 100.0 -> mark 101.0000
    oracle 105.0 -> mark 101.0000
    oracle 105.0 -> mark 105.4427
    (105)
    |}]
;;
