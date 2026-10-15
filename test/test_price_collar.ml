open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

let btc_i = Instrument.create btc ~size_decimals:5 ~price_tick:(px "0.1") ~max_leverage:40

(* Hyperliquid-style: tick 0.000001 and at most five significant figures. *)
let alt_i =
  Instrument.create
    (Symbol.of_string "ALT")
    ~max_significant_figures:5
    ~size_decimals:0
    ~price_tick:(px "0.000001")
    ~max_leverage:10
;;

let config ?(action = Price_collar.Action.Reject) band : Price_collar.Config.t =
  { reference = Mark; band; action }
;;

let show c i reference =
  let reference = px reference in
  printf
    !"%{Price} .. %{Price}\n"
    (Price_collar.lower c i ~reference)
    (Price_collar.upper c i ~reference)
;;

let%expect_test "bands in bps and ticks, rounded inward to the tick" =
  show (config (Bps 50)) btc_i "100000";
  show (config (Bps 1)) btc_i "100000.05";
  show (config (Ticks 3)) btc_i "100000";
  [%expect {|
    99500 .. 100500
    99990.1 .. 100010
    99999.7 .. 100000.3
    |}]
;;

let%expect_test "significant figures narrow the band to valid prices" =
  (* 12.3456 +- 1% = 12.222144 .. 12.469056; five figures allow 3 decimals here. *)
  show (config (Bps 100)) alt_i "12.3456";
  show (config (Bps 100)) alt_i "0.0123456";
  show (config (Bps 100)) alt_i "123456";
  [%expect {|
    12.223 .. 12.469
    0.012223 .. 0.012469
    122222 .. 124690
    |}]
;;

let%expect_test "the lower bound is at least one tick" =
  show (config (Bps 20_000)) btc_i "100";
  show (config (Ticks 10)) btc_i "0.5";
  [%expect {|
    0.1 .. 300
    0.1 .. 1.5
    |}]
;;

let%expect_test "validate" =
  print_s [%sexp (Price_collar.Config.validate (config (Bps 0)) : unit Or_error.t)];
  print_s [%sexp (Price_collar.Config.validate (config (Ticks 1)) : unit Or_error.t)];
  [%expect
    {|
    (Error
     ("Price_collar: band must be positive"
      (t ((reference Mark) (band (Bps 0)) (action Reject)))))
    (Ok ())
    |}]
;;

let%test_unit "bounds are valid prices on the right side of the reference, within the \
               band"
  =
  let gen =
    let open Quickcheck.Generator.Let_syntax in
    let%bind instrument = Quickcheck.Generator.of_list [ btc_i; alt_i ] in
    let tick = Price.to_units instrument.price_tick in
    let%bind ticks = Int.gen_incl 1 2_000_000_000 in
    let%bind band =
      Quickcheck.Generator.union
        [ Int.gen_incl 1 5_000
          |> Quickcheck.Generator.map ~f:(fun n -> Price_collar.Band.Bps n)
        ; Int.gen_incl 1 1_000
          |> Quickcheck.Generator.map ~f:(fun n -> Price_collar.Band.Ticks n)
        ]
    in
    return (instrument, Price.of_units (ticks * tick), band)
  in
  Quickcheck.test
    gen
    ~sexp_of:[%sexp_of: Instrument.t * Price.t * Price_collar.Band.t]
    ~f:(fun (i, reference, band) ->
      let c = config band in
      let up = Price_collar.upper c i ~reference in
      let lo = Price_collar.lower c i ~reference in
      (* In price units, with one unit of slack for the float width. *)
      let u = Price.to_units in
      let width =
        match band with
        | Bps n -> Float.of_int (u reference) *. Float.of_int n /. 10_000.
        | Ticks n -> Float.of_int (n * u i.price_tick)
      in
      let within d = Float.( <= ) (Float.of_int d) (width +. 1.) in
      assert (Instrument.valid_price i up && Instrument.valid_price i lo);
      let step = u (Price_collar.step i reference) in
      assert (Price.( >= ) up reference);
      assert (Price.( <= ) lo reference || Price.equal lo i.price_tick);
      (* Within the band, or one grid step when the band is narrower than the grid. *)
      assert (within (u up - u reference) || u up - u reference < step);
      (* The lower bound is the band edge, or one tick when the band reaches zero. *)
      assert (
        within (u reference - u lo)
        || u reference - u lo < step
        || Price.equal lo i.price_tick))
;;
