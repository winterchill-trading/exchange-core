open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

let config = Halt_rule.Config.default

let%expect_test "moves and levels" =
  let reference = px "100000" in
  List.iter
    [ "100000", 0
    ; "93000.1", 0
    ; "93000", 0
    ; "92999.9", 0
    ; "87000", 1
    ; "79999", 0
    ; "80000", 2
    ; "120000", 2
    ; "120000", 3
    ]
    ~f:(fun (p, triggered) ->
      let px = px p in
      printf
        !"%{Price} triggered=%d move=%d level=%{sexp: int option}\n"
        px
        triggered
        (Halt_rule.move_bps ~reference ~px)
        (Halt_rule.level_to_trigger config ~triggered ~reference ~px));
  [%expect
    {|
    100000 triggered=0 move=0 level=()
    93000.1 triggered=0 move=699 level=()
    93000 triggered=0 move=700 level=(0)
    92999.9 triggered=0 move=700 level=(0)
    87000 triggered=1 move=1300 level=(1)
    79999 triggered=0 move=2000 level=(2)
    80000 triggered=2 move=2000 level=(2)
    120000 triggered=2 move=2000 level=(2)
    120000 triggered=3 move=2000 level=()
    |}]
;;

let%expect_test "validate" =
  let show levels =
    print_s
      [%sexp (Halt_rule.Config.validate { config with levels } |> Result.is_ok : bool)]
  in
  show config.levels;
  show [];
  show [ { move_bps = 700; duration_ns = None }; { move_bps = 700; duration_ns = None } ];
  show [ { move_bps = 700; duration_ns = Some 0 } ];
  [%expect {|
    true
    false
    false
    false
    |}]
;;

let%expect_test "watch list" =
  let eth = Symbol.of_string "ETH" in
  printf
    "%b %b %b\n"
    (Halt_rule.watches config eth)
    (Halt_rule.watches { config with watch = [ btc ] } btc)
    (Halt_rule.watches { config with watch = [ btc ] } eth);
  [%expect {| true true false |}]
;;
