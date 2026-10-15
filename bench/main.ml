open! Core
open Core_bench
module Scenario = Exchange_core_bench_scenario.Scenario

(* Run with a short quota, e.g. [-quota 2]: every fill appends to the per-account fill
   history, so a long run grows the heap. *)
(* The same exchange with a collar (50 bps around the mark, re-pricing) and the default
   halt rule, so the guarded order path can be compared with the plain one. *)
let guarded () =
  let ex = Scenario.create () in
  let open Exchange_core_engine in
  (* The scenario marks BTC at 50,000, the collar's reference. *)
  ok_exn
    (Exchange.set_collar
       ex
       Scenario.btc
       (Some { reference = Mark; band = Bps 50; action = Reprice }));
  ok_exn (Exchange.set_halt_rule ex (Some Halt_rule.Config.default));
  ex
;;

let () =
  let ex = Scenario.create () in
  let guarded = guarded () in
  Command_unix.run
    (Bench.make_command
       [ Bench.Test.create ~name:"step (1000 accounts)" (Scenario.step ex)
       ; Bench.Test.create
           ~name:"submit IOC buy+sell (2 fills)"
           (Scenario.match_round_trip ex)
       ; Bench.Test.create
           ~name:"submit IOC buy+sell (2 fills), collar+halt"
           (Scenario.match_round_trip guarded)
       ; Bench.Test.create ~name:"submit+cancel resting" (Scenario.place_and_cancel ex)
       ; Bench.Test.create
           ~name:"submit+cancel resting, collar+halt"
           (Scenario.place_and_cancel guarded)
       ; Bench.Test.create
           ~name:"maker submit+cancel (100 resting)"
           (Scenario.maker_place_and_cancel ex)
       ; Bench.Test.create
           ~name:"submit+cancel (500 own resting)"
           (Scenario.quoter_place_and_cancel (Scenario.create_quoter ()))
       ])
;;
