open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

(* [Clearinghouse.mark_to_market] and [apply_funding] against the original implementation:
   every account sorted by id, every position recomputed from the public API. Two
   clearinghouses see the same random fills, deposits, marks and funding; one is marked by
   the engine and the other by the reference, and their outputs and final state must
   match. *)

let eth = Symbol.of_string "ETH"

let instruments =
  List.map [ btc; eth ] ~f:(fun symbol ->
    Instrument.create symbol ~size_decimals:3 ~price_tick:(px "0.1") ~max_leverage:20)
;;

let n_accounts = 12

module Op = struct
  type t =
    | Fill of
        { taker : int
        ; maker_offset : int
        ; side : Side.t
        ; eth : bool
        ; px : int
        ; sz : int
        }
    | Deposit of
        { account : int
        ; amount : int
        }
    | Mark of
        { btc : int
        ; eth : int
        }
    | Funding of
        { eth : bool
        ; rate_bps : int
        ; mark : int
        }
  [@@deriving sexp_of]

  let account = Int.gen_incl 1 n_accounts
  let px = Int.gen_incl 50 150

  let quickcheck_generator =
    let open Quickcheck.Generator.Let_syntax in
    Quickcheck.Generator.weighted_union
      [ ( 6.
        , let%map taker = account
          and maker_offset = Int.gen_incl 1 (n_accounts - 1)
          and side = Quickcheck.Generator.of_list Side.all
          and eth = Bool.quickcheck_generator
          and px
          and sz = Int.gen_incl 1 50 in
          Fill { taker; maker_offset; side; eth; px; sz } )
      ; ( 1.
        , let%map account
          and amount = Int.gen_incl 0 300 in
          Deposit { account; amount } )
      ; ( 2.
        , let%map btc = px
          and eth = px in
          Mark { btc; eth } )
      ; ( 1.
        , let%map eth = Bool.quickcheck_generator
          and rate_bps = Int.gen_incl (-50) 50
          and mark = px in
          Funding { eth; rate_bps; mark } )
      ]
  ;;
end

let tid = ref 0

let fill ~taker ~maker ~side ~symbol p s : Order_book.Fill.t =
  incr tid;
  { tid = Trade_id.of_int !tid
  ; symbol
  ; px = Price.of_int p
  ; sz = Size.of_string (sprintf "%d.%d" (s / 10) (s % 10))
  ; taker_side = side
  ; taker_oid = Order_id.of_int (2 * !tid)
  ; maker_oid = Order_id.of_int ((2 * !tid) + 1)
  ; taker = acct taker
  ; maker = acct maker
  ; taker_cloid = None
  ; maker_cloid = None
  ; time = 0
  }
;;

let reference_mark_to_market ch ~mark =
  List.concat_map (Clearinghouse.accounts ch) ~f:(fun state ->
    let account = state.account in
    let positions = Account_state.open_positions state in
    if List.is_empty positions
       || Usd.( >= )
            (Clearinghouse.equity ch account ~mark)
            (Clearinghouse.maintenance_margin ch account ~mark)
    then []
    else
      List.map positions ~f:(fun p ->
        let px = Option.value (mark p.symbol) ~default:p.entry_px in
        let size = p.size in
        let pnl = Position.close_at p ~px in
        Account_state.add_balance state pnl;
        { Clearinghouse.Liquidation.account; symbol = p.symbol; size; px; pnl }))
;;

(* Who funding should charge, computed before it is applied. *)
let reference_funded ch ~symbol =
  List.filter_map (Clearinghouse.accounts ch) ~f:(fun state ->
    Account_state.position state symbol
    |> Option.map ~f:(fun (p : Position.t) -> state.account, p.size))
;;

let state ch =
  List.map (Clearinghouse.accounts ch) ~f:(fun (a : Account_state.t) ->
    [%sexp
      (a.account : Account.t)
      , (a.balance : Usd.t)
      , (Account_state.open_positions a : Position.t list)])
;;

let run ops =
  let engine = Clearinghouse.create instruments in
  let reference = Clearinghouse.create instruments in
  let both f =
    f engine;
    f reference
  in
  List.iter ops ~f:(fun (op : Op.t) ->
    (match op with
     | Fill { taker; maker_offset; side; eth = is_eth; px; sz } ->
       let maker = ((taker - 1 + maker_offset) % n_accounts) + 1 in
       let symbol = if is_eth then eth else btc in
       let f = fill ~taker ~maker ~side ~symbol px sz in
       both (fun ch ->
         ignore
           (Clearinghouse.settle_fill ch f
            : Clearinghouse.Settlement.t * Clearinghouse.Settlement.t))
     | Deposit { account; amount } ->
       both (fun ch -> Clearinghouse.deposit ch (acct account) (Usd.of_int amount))
     | Mark { btc = b; eth = e } ->
       let mark symbol = Some (Price.of_int (if Symbol.equal symbol btc then b else e)) in
       [%test_result: Clearinghouse.Liquidation.t list]
         (Clearinghouse.mark_to_market engine ~mark)
         ~expect:(reference_mark_to_market reference ~mark)
     | Funding { eth = is_eth; rate_bps; mark } ->
       let symbol = if is_eth then eth else btc in
       let expect = reference_funded engine ~symbol in
       let rate = Float.of_int rate_bps /. 10_000. in
       let mark = Price.of_int mark in
       let payments = Clearinghouse.apply_funding engine ~symbol ~rate ~mark in
       [%test_result: (Account.t * Size.t) list]
         (List.map payments ~f:(fun (p : Clearinghouse.Funding_payment.t) ->
            p.account, p.size))
         ~expect;
       [%test_result: Clearinghouse.Funding_payment.t list]
         (Clearinghouse.apply_funding reference ~symbol ~rate ~mark)
         ~expect:payments);
    [%test_result: Sexp.t list] (state engine) ~expect:(state reference))
;;

let%test_unit "mark_to_market and apply_funding match the reference" =
  Quickcheck.test
    ~trials:300
    ~sexp_of:[%sexp_of: Op.t list]
    (List.gen_with_length 60 Op.quickcheck_generator)
    ~f:run
;;

let%expect_test "the generator liquidates" =
  let liquidated = ref 0 in
  Quickcheck.iter
    ~seed:(`Deterministic "liquidations")
    ~trials:100
    (List.gen_with_length 60 Op.quickcheck_generator)
    ~f:(fun ops ->
      let ch = Clearinghouse.create instruments in
      List.iter ops ~f:(fun (op : Op.t) ->
        match op with
        | Fill { taker; maker_offset; side; eth = is_eth; px; sz } ->
          let maker = ((taker - 1 + maker_offset) % n_accounts) + 1 in
          let symbol = if is_eth then eth else btc in
          ignore
            (Clearinghouse.settle_fill ch (fill ~taker ~maker ~side ~symbol px sz)
             : Clearinghouse.Settlement.t * Clearinghouse.Settlement.t)
        | Mark { btc = b; eth = e } ->
          let mark symbol =
            Some (Price.of_int (if Symbol.equal symbol btc then b else e))
          in
          liquidated := !liquidated + List.length (Clearinghouse.mark_to_market ch ~mark)
        | Deposit _ | Funding _ -> ()));
  print_s [%message (!liquidated > 0 : bool)];
  [%expect {| ("(!liquidated) > 0" true) |}]
;;
