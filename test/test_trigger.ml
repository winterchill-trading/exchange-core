open! Core
open! Exchange_core
open Helpers

let%expect_test "which way the mark has to move" =
  List.iter Trigger.Kind.all ~f:(fun kind ->
    List.iter Side.all ~f:(fun side ->
      let trigger = { Trigger.trigger_px = px "100"; kind } in
      let at m = Trigger.fires trigger ~side ~mark:(px m) in
      printf
        !"%{sexp: Trigger.Kind.t} %{sexp: Side.t}: above=%b  99:%b 100:%b 101:%b\n"
        kind
        side
        (Trigger.fires_above trigger ~side)
        (at "99")
        (at "100")
        (at "101")));
  [%expect
    {|
    Take_profit Buy: above=false  99:true 100:true 101:false
    Take_profit Sell: above=true  99:false 100:true 101:true
    Stop_loss Buy: above=true  99:false 100:true 101:true
    Stop_loss Sell: above=false  99:true 100:true 101:false
    |}]
;;
