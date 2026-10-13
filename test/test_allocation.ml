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

let%expect_test "minor words per call" =
  let ex = Scenario.create () in
  List.iter
    [ "step", Scenario.step ex
    ; "submit IOC buy+sell", Scenario.match_round_trip ex
    ; "submit+cancel", Scenario.place_and_cancel ex
    ]
    ~f:(fun (name, f) -> printf "%-20s %d\n" name (words_per_run f));
  [%expect
    {|
    step                 17
    submit IOC buy+sell  462
    submit+cancel        331
    |}]
;;
