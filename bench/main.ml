open! Core
open Core_bench
module Scenario = Exchange_core_bench_scenario.Scenario

(* Run with a short quota, e.g. [-quota 2]: every fill appends to the per-account fill
   history, so a long run grows the heap. *)
let () =
  let ex = Scenario.create () in
  Command_unix.run
    (Bench.make_command
       [ Bench.Test.create ~name:"step (1000 accounts)" (Scenario.step ex)
       ; Bench.Test.create
           ~name:"submit IOC buy+sell (2 fills)"
           (Scenario.match_round_trip ex)
       ; Bench.Test.create ~name:"submit+cancel resting" (Scenario.place_and_cancel ex)
       ; Bench.Test.create
           ~name:"maker submit+cancel (100 resting)"
           (Scenario.maker_place_and_cancel ex)
       ])
;;
