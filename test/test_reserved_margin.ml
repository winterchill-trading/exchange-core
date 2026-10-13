open! Core
open! Exchange_core
open! Exchange_core_engine
open Helpers

(* [Exchange.reserved_margin] against a walk over the account's open orders, after every
   step of random places, IOC sweeps, cancels, leverage changes and mark moves. *)

module Notional = Fixed_decimal.Product (Price) (Size) (Usd)

let n_accounts = 4

module Op = struct
  type t =
    | Place of
        { account : int
        ; side : Side.t
        ; ticks : int
        ; size : int
        ; ioc : bool
        ; reduce_only : bool
        }
    | Cancel of
        { account : int
        ; pick : int
        }
    | Leverage of
        { account : int
        ; leverage : int
        }
    | Mark of int
  [@@deriving sexp_of]

  let account = Int.gen_incl 1 n_accounts

  let quickcheck_generator =
    let open Quickcheck.Generator.Let_syntax in
    Quickcheck.Generator.weighted_union
      [ ( 8.
        , let%map account
          and side = Quickcheck.Generator.of_list Side.all
          and ticks = Int.gen_incl (-20) 20
          and size = Int.gen_incl 1 30
          and ioc =
            Quickcheck.Generator.weighted_union [ 1., return true; 4., return false ]
          and reduce_only =
            Quickcheck.Generator.weighted_union [ 1., return true; 5., return false ]
          in
          Place { account; side; ticks; size; ioc; reduce_only } )
      ; ( 3.
        , let%map account
          and pick = Int.gen_incl 0 20 in
          Cancel { account; pick } )
      ; ( 1.
        , let%map account
          and leverage = Int.gen_incl 1 40 in
          Leverage { account; leverage } )
      ; (1., Int.gen_incl 80 120 >>| fun m -> Mark m)
      ]
  ;;
end

let reference ex account =
  List.sum (module Usd) (Exchange.open_orders ex account) ~f:(fun (o : Open_order.t) ->
    match
      Option.bind (Exchange.book ex o.symbol) ~f:(fun b -> Order_book.find b o.order_id)
    with
    | Some r when not r.reduce_only ->
      Usd.div_int
        (Notional.mul r.px r.remaining)
        (Clearinghouse.leverage (Exchange.clearinghouse ex) account o.symbol)
    | Some _ | None -> Usd.zero)
;;

let run ops =
  let ex = Exchange.create () in
  for n = 1 to n_accounts do
    Exchange.deposit ex (acct n) (usd "5000")
  done;
  Exchange.set_mark ex btc (px "100");
  List.iter ops ~f:(fun (op : Op.t) ->
    (match op with
     | Place { account; side; ticks; size; ioc; reduce_only } ->
       let p = Price.( + ) (px "100") (Price.of_string (sprintf "%d" ticks)) in
       let tif = if ioc then Tif.Ioc else Gtc in
       ignore
         (Exchange.place
            ex
            (acct account)
            (Order_request.limit
               ~tif
               ~reduce_only
               btc
               side
               ~px:p
               ~size:(Size.of_string (sprintf "%d.%d" (size / 10) (size % 10))))
          : Order_status.t)
     | Cancel { account; pick } ->
       let orders = Exchange.open_orders ex (acct account) in
       if not (List.is_empty orders)
       then (
         let o = List.nth_exn orders (pick % List.length orders) in
         ignore
           (Exchange.cancel ex (acct account) ~symbol:o.symbol o.order_id
            : Cancel_status.t))
     | Leverage { account; leverage } ->
       ignore (Exchange.set_leverage ex (acct account) btc leverage : unit Or_error.t)
     | Mark m -> Exchange.set_mark ex btc (Price.of_int m));
    for n = 1 to n_accounts do
      [%test_result: Usd.t]
        (Exchange.reserved_margin ex (acct n))
        ~expect:(reference ex (acct n))
    done)
;;

let%test_unit "reserved_margin matches a walk over open orders" =
  Quickcheck.test
    ~trials:200
    ~sexp_of:[%sexp_of: Op.t list]
    (List.gen_with_length 80 Op.quickcheck_generator)
    ~f:run
;;
