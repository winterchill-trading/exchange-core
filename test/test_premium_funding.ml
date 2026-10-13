open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

let config = Premium_funding.Config.default
let hour = Time_ns.Span.hour

let%expect_test "impact notional per symbol" =
  List.iter [ "BTC"; "ETH"; "SOL" ] ~f:(fun s ->
    print_s
      [%sexp
        (s : string)
        , (Premium_funding.Config.impact_notional config (Symbol.of_string s) : Usd.t)]);
  [%expect {|
    (BTC 20000)
    (ETH 20000)
    (SOL 6000)
    |}]
;;

let%expect_test "impact prices walk the book" =
  let level p s = px p, sz s in
  let bids = [ level "100" "100"; level "99" "1000" ] in
  let asks = [ level "101" "10" ] in
  let show notional =
    print_s
      [%sexp
        (Premium_funding.impact_pxs ~bids ~asks ~notional:(usd notional)
         : float option * float option)]
  in
  show "6000";
  (* Beyond the first level, and beyond everything the ask side holds. *)
  show "20000";
  print_s
    [%sexp
      (Premium_funding.impact_pxs ~bids:[] ~asks ~notional:(usd "1000")
       : float option * float option)];
  [%expect {|
    ((100) (101))
    ((99.497487437185924) (101))
    (() (101))
    |}]
;;

let%expect_test "premium and the hourly rate" =
  let premium ~oracle ~bid ~ask =
    Premium_funding.premium ~oracle ~impact_bid:bid ~impact_ask:ask
  in
  (* The documented example: impact bid 10,100 against an oracle of 10,000. *)
  let p = premium ~oracle:10_000. ~bid:(Some 10_100.) ~ask:(Some 10_120.) in
  printf
    "premium %g, 8h rate %g\n"
    p
    (Premium_funding.rate config ~average_premium:p ~interval:(Time_ns.Span.of_hr 8.));
  (* Inside the spread: no premium, so the interest rate alone, one eighth per hour. *)
  let p = premium ~oracle:100. ~bid:(Some 99.9) ~ask:(Some 100.1) in
  printf
    "premium %g, hourly rate %g\n"
    p
    (Premium_funding.rate config ~average_premium:p ~interval:hour);
  (* A discount, and a premium large enough to hit the 4% hourly cap. *)
  let p = premium ~oracle:100. ~bid:(Some 98.) ~ask:(Some 99.) in
  printf
    "premium %g, hourly rate %g\n"
    p
    (Premium_funding.rate config ~average_premium:p ~interval:hour);
  printf "capped %g\n" (Premium_funding.rate config ~average_premium:1. ~interval:hour);
  [%expect
    {|
    premium 0.01, 8h rate 0.0095
    premium 0, hourly rate 1.25e-05
    premium -0.01, hourly rate -0.0011875
    capped 0.04
    |}]
;;
