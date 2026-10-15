open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

type action =
  | Limit of
      { account : int
      ; side : Side.t
      ; offset : int (** half units from 1000 *)
      ; size : int
      ; tif : Tif.t
      }
  | Market of
      { account : int
      ; side : Side.t
      ; size : int
      }
  | Mark of { offset : int }
[@@deriving sexp_of]

let price_of offset = Price.( + ) (px "1000") (Price.of_units (offset * 50_000_000))

let gen_action =
  let open Quickcheck.Generator.Let_syntax in
  let side = Quickcheck.Generator.of_list Side.all in
  let account = Int.gen_incl 1 4 in
  let offset = Int.gen_incl (-120) 120 in
  let size = Int.gen_incl 1 3 in
  Quickcheck.Generator.weighted_union
    [ ( 6.
      , let%map account
        and side
        and offset
        and size
        and tif = Quickcheck.Generator.of_list Tif.all in
        Limit { account; side; offset; size; tif } )
    ; ( 1.
      , let%map account and side and size in
        Market { account; side; size } )
    ; ( 1.
      , let%map offset in
        Mark { offset } )
    ]
;;

let gen_collar =
  let open Quickcheck.Generator.Let_syntax in
  let%map reference =
    Quickcheck.Generator.of_list Price_collar.Reference.[ Last_trade; Mid; Mark ]
  and band =
    Quickcheck.Generator.union
      [ Int.gen_incl 1 500
        |> Quickcheck.Generator.map ~f:(fun n -> Price_collar.Band.Bps n)
      ; Int.gen_incl 1 300
        |> Quickcheck.Generator.map ~f:(fun n -> Price_collar.Band.Ticks n)
      ]
  and action = Quickcheck.Generator.of_list Price_collar.Action.[ Reject; Reprice ] in
  { Price_collar.Config.reference; band; action }
;;

let check_fill ~(side : Side.t) ~bound (fill : Order_book.Fill.t) =
  let ok =
    match side with
    | Buy -> Price.( <= ) fill.px bound
    | Sell -> Price.( >= ) fill.px bound
  in
  if not ok
  then
    raise_s
      [%message
        "fill beyond the collar" (side : Side.t) (bound : Price.t) (fill.px : Price.t)]
;;

let run collar actions =
  let ex = Exchange.create () in
  List.iter [ 1; 2; 3; 4 ] ~f:(fun n -> Exchange.deposit ex (acct n) (usd "1000000000"));
  ok_exn (Exchange.set_collar ex btc (Some collar));
  let instrument = Option.value_exn (Exchange.instrument ex btc) in
  let fills = ref 0 in
  List.iter actions ~f:(fun action ->
    let place account side req =
      let bound =
        Option.map (Exchange.collar_reference ex btc) ~f:(fun reference ->
          Price_collar.bound collar instrument ~reference ~side)
      in
      ignore (Exchange.place ex (acct account) req : Order_status.t);
      List.iter (Exchange.drain_events ex) ~f:(function
        | Fill { fill; _ } ->
          incr fills;
          Option.iter bound ~f:(fun bound -> check_fill ~side ~bound fill)
        | _ -> ())
    in
    match action with
    | Limit { account; side; offset; size; tif } ->
      place
        account
        side
        (Order_request.limit ~tif btc side ~px:(price_of offset) ~size:(Size.of_int size))
    | Market { account; side; size } ->
      place account side (Order_request.market btc side ~size:(Size.of_int size))
    | Mark { offset } ->
      Exchange.set_mark ex btc (price_of offset);
      ignore (Exchange.drain_events ex : Event.t list));
  !fills, Exchange.guard_stats ex
;;

let%test_unit "no fill beyond the collar on the aggressor's side" =
  Quickcheck.test
    ~trials:500
    (Quickcheck.Generator.both
       gen_collar
       (Quickcheck.Generator.list_with_length 80 gen_action))
    ~sexp_of:[%sexp_of: Price_collar.Config.t * action list]
    ~f:(fun (collar, actions) -> ignore (run collar actions : int * Guard_event.Stats.t))
;;

let%expect_test "the property sees fills, guard events of both kinds" =
  (* Guard against a vacuous property: the generated flows do trade and do meet the
     collar. *)
  let fills = ref 0 in
  let rejected = ref 0 in
  let repriced = ref 0 in
  Quickcheck.iter
    ~seed:(`Deterministic "collar")
    ~trials:50
    (Quickcheck.Generator.list_with_length 80 gen_action)
    ~f:(fun actions ->
      List.iter
        Price_collar.Action.[ Reject; Reprice ]
        ~f:(fun action ->
          let collar = { Price_collar.Config.reference = Mark; band = Bps 100; action } in
          let n, (stats : Guard_event.Stats.t) = run collar actions in
          fills := !fills + n;
          rejected := !rejected + stats.collar_rejected;
          repriced := !repriced + stats.collar_repriced));
  print_s [%sexp (!fills > 1000 : bool), (!rejected > 50 : bool), (!repriced > 50 : bool)];
  [%expect {| (true true true) |}]
;;
