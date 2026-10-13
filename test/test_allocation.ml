open! Core
module Scenario = Exchange_core_bench_scenario.Scenario

(* Minor-heap words per call on the bench scenario (1000 accounts with a BTC position, 100
   resting orders). A change here is a change in allocation behaviour. *)

let words_per_run f =
  let runs = 200 in
  (* Warm up so one-off growth (hash table resize) is not counted. *)
  f ();
  let before = Gc.minor_words () in
  for _ = 1 to runs do
    f ()
  done;
  Float.iround_nearest_exn (Float.of_int (Gc.minor_words () - before) /. Float.of_int runs)
;;

(* The submit paths compile to slightly different allocation on amd64 (CI) and arm64, so
   each case lists the words measured on both; a mismatch prints the new number. *)
let%expect_test "minor words per call" =
  let ex = Scenario.create () in
  List.iter
    [ "step", Scenario.step ex, [ 17 ]
    ; "submit IOC buy+sell", Scenario.match_round_trip ex, [ 460; 474 ]
    ; "submit+cancel", Scenario.place_and_cancel ex, [ 335; 342 ]
    ; "maker submit+cancel", Scenario.maker_place_and_cancel ex, [ 338; 345 ]
    ; ( "quoter submit+cancel"
      , Scenario.quoter_place_and_cancel (Scenario.create_quoter ())
      , [ 375; 382 ] )
    ]
    ~f:(fun (name, f, pinned) ->
      let words = words_per_run f in
      if List.mem pinned words ~equal:Int.equal
      then printf "%-21s pinned\n" name
      else
        printf
          "%-21s %d (pinned %s)\n"
          name
          words
          (Sexp.to_string [%sexp (pinned : int list)]));
  [%expect
    {|
    step                  pinned
    submit IOC buy+sell   pinned
    submit+cancel         pinned
    maker submit+cancel   pinned
    quoter submit+cancel  pinned
    |}]
;;
