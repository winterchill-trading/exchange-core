open! Core
open! Exchange_core
module Notional = Fixed_decimal.Product (Price) (Size) (Usd)

module Config = struct
  type t =
    { instruments : Instrument.t list
    ; default_leverage : int
    ; funding_interval_ns : int
    ; default_funding_rate : float
    ; min_order_value : Usd.t
    ; market_slippage_bps : int
    ; l2_levels : int
    }
  [@@deriving sexp_of]

  let default_instruments =
    let instrument name size_decimals tick max_leverage =
      Instrument.create
        (Symbol.of_string name)
        ~size_decimals
        ~price_tick:(Price.of_string tick)
        ~max_leverage
    in
    [ instrument "BTC" 5 "0.1" 40
    ; instrument "ETH" 4 "0.01" 25
    ; instrument "SOL" 2 "0.0001" 20
    ]
  ;;

  let default =
    { instruments = default_instruments
    ; default_leverage = 20
    ; funding_interval_ns = Time_ns.Span.to_int_ns Time_ns.Span.hour
    ; default_funding_rate = 0.0000125
    ; min_order_value = Usd.of_int 10
    ; market_slippage_bps = 500
    ; l2_levels = 20
    }
  ;;
end

module Target = Target

type t =
  { config : Config.t
  ; clearinghouse : Clearinghouse.t
  ; books : Order_book.t Symbol.Table.t
  ; marks : Price.t Symbol.Table.t (** explicit marks from [set_mark] *)
  ; last_trade : Price.t Symbol.Table.t
  ; funding_rates : float Symbol.Table.t
  ; owner_orders : Symbol.t Order_id.Table.t Account.Table.t (** owner -> oid -> symbol *)
  ; client_ids : Order_id.t Client_order_id.Table.t Account.Table.t
  ; fills : Execution.t list Account.Table.t (** newest first *)
  ; events : Event.t Queue.t
  ; mutable recorders : (Input.t -> unit) list (** oldest first *)
  ; mutable time : int
  ; mutable next_oid : int
  ; mutable next_tid : int
  ; mutable next_funding : int
  }

let create ?(config = Config.default) () =
  let books = Symbol.Table.create () in
  List.iter config.instruments ~f:(fun i ->
    Hashtbl.set books ~key:i.symbol ~data:(Order_book.create i.symbol));
  { config
  ; clearinghouse =
      Clearinghouse.create ~default_leverage:config.default_leverage config.instruments
  ; books
  ; marks = Symbol.Table.create ()
  ; last_trade = Symbol.Table.create ()
  ; funding_rates = Symbol.Table.create ()
  ; owner_orders = Account.Table.create ()
  ; client_ids = Account.Table.create ()
  ; fills = Account.Table.create ()
  ; events = Queue.create ()
  ; recorders = []
  ; time = 0
  ; next_oid = 1
  ; next_tid = 1
  ; next_funding = config.funding_interval_ns
  }
;;

let config t = t.config
let instruments t = t.config.instruments
let instrument t symbol = Instrument.find t.config.instruments symbol
let clearinghouse t = t.clearinghouse
let now t = t.time
let emit t event = Queue.enqueue t.events event
let record_inputs t ~f = t.recorders <- t.recorders @ [ f ]

(* Reports a request that has been performed to the input recorders. *)
let record t input = List.iter t.recorders ~f:(fun f -> f input)

let drain_events t =
  let events = Queue.to_list t.events in
  Queue.clear t.events;
  events
;;

let book t symbol = Hashtbl.find t.books symbol
let deposit t account usd =
  Clearinghouse.deposit t.clearinghouse account usd;
  record t (Deposit { account; usd })
;;

let set_leverage t account symbol leverage =
  let result = Clearinghouse.set_leverage t.clearinghouse account symbol leverage in
  record t (Set_leverage { account; symbol; leverage });
  result
;;

let mark t symbol =
  match Hashtbl.find t.marks symbol with
  | Some _ as mark -> mark
  | None ->
    (match Hashtbl.find t.last_trade symbol with
     | Some _ as px -> px
     | None -> Option.bind (book t symbol) ~f:Order_book.mid)
;;

let mark_fn t : Clearinghouse.mark = mark t

(* Order indexes *)

let owner_index t account =
  Hashtbl.find_or_add t.owner_orders account ~default:Order_id.Table.create
;;

let client_id_index t account =
  Hashtbl.find_or_add t.client_ids account ~default:Client_order_id.Table.create
;;

let index_resting t (o : Order_book.Resting_order.t) ~symbol =
  Hashtbl.set (owner_index t o.owner) ~key:o.oid ~data:symbol;
  Option.iter o.cloid ~f:(fun cid ->
    Hashtbl.set (client_id_index t o.owner) ~key:cid ~data:o.oid)
;;

let unindex t ~owner ~oid ~cloid =
  Option.iter (Hashtbl.find t.owner_orders owner) ~f:(fun tbl -> Hashtbl.remove tbl oid);
  Option.iter cloid ~f:(fun cid ->
    Option.iter (Hashtbl.find t.client_ids owner) ~f:(fun tbl -> Hashtbl.remove tbl cid))
;;

let open_order_of_resting ~symbol ?size (o : Order_book.Resting_order.t) : Open_order.t =
  { symbol
  ; side = o.side
  ; px = o.px
  ; size = Option.value size ~default:o.remaining
  ; orig_size = Some o.orig_sz
  ; order_id = o.oid
  ; client_order_id = o.cloid
  ; timestamp = o.timestamp
  }
;;

let resting_orders_of t account =
  match Hashtbl.find t.owner_orders account with
  | None -> []
  | Some tbl ->
    Hashtbl.to_alist tbl
    |> List.filter_map ~f:(fun (oid, symbol) ->
      Option.bind (book t symbol) ~f:(fun b -> Order_book.find b oid)
      |> Option.map ~f:(fun o -> symbol, o))
;;

let remove_resting t ~symbol oid ~reason =
  match Option.bind (book t symbol) ~f:(fun b -> Order_book.cancel b oid) with
  | None -> false
  | Some o ->
    unindex t ~owner:o.owner ~oid ~cloid:o.cloid;
    emit
      t
      (Order_cancelled
         { account = o.owner
         ; order = open_order_of_resting ~symbol o
         ; reason
         ; time = t.time
         });
    true
;;

let reserved_margin t account =
  resting_orders_of t account
  |> List.filter ~f:(fun (_, (o : Order_book.Resting_order.t)) -> not o.reduce_only)
  |> List.map ~f:(fun (symbol, (o : Order_book.Resting_order.t)) ->
    Usd.div_int
      (Notional.mul o.px o.remaining)
      (Clearinghouse.leverage t.clearinghouse account symbol))
  |> Usd.sum
;;

(* Matching results *)

let record_fill t book (fill : Order_book.Fill.t) =
  let taker, maker = Clearinghouse.settle_fill t.clearinghouse fill in
  Hashtbl.add_multi t.fills ~key:fill.taker ~data:{ Execution.fill; settlement = taker };
  Hashtbl.add_multi t.fills ~key:fill.maker ~data:{ Execution.fill; settlement = maker };
  Hashtbl.set t.last_trade ~key:fill.symbol ~data:fill.px;
  emit t (Fill { fill; taker; maker });
  (* A maker that is no longer on the book was filled completely. *)
  if Option.is_none (Order_book.find book fill.maker_oid)
  then (
    let tbl = Hashtbl.find t.owner_orders fill.maker in
    if Option.value_map tbl ~default:false ~f:(fun tbl -> Hashtbl.mem tbl fill.maker_oid)
    then (
      unindex t ~owner:fill.maker ~oid:fill.maker_oid ~cloid:fill.maker_cloid;
      emit
        t
        (Order_filled
           { account = fill.maker
           ; order =
               { symbol = fill.symbol
               ; side = Order_book.Fill.maker_side fill
               ; px = fill.px
               ; size = Size.zero
               ; orig_size = None
               ; order_id = fill.maker_oid
               ; client_order_id = fill.maker_cloid
               ; timestamp = fill.time
               }
           ; time = t.time
           })))
;;

let avg_px (fills : Order_book.Fill.t list) ~filled =
  let notional = Usd.sum (List.map fills ~f:(fun f -> Notional.mul f.px f.sz)) in
  Notional.div notional filled
;;

let emit_reject ?symbol ?order_id ?client_order_id t account reason : Order_status.t =
  emit
    t
    (Order_rejected { account; symbol; order_id; client_order_id; reason; time = t.time });
  Rejected reason
;;

let next_order_id t =
  let order_id = Order_id.of_int t.next_oid in
  t.next_oid <- t.next_oid + 1;
  order_id
;;

(* Runs [submit] with [order_id] and turns the book's result into an order status,
   emitting events and settling fills. *)
let submit
  t
  account
  ~symbol
  ~side
  ~limit_px
  ~order_id
  ~client_order_id
  ~(submit : oid:Order_id.t -> next_tid:(unit -> Trade_id.t) -> Order_book.Result.t)
  : Order_status.t
  =
  let book = Option.value_exn (book t symbol) in
  let next_tid () =
    let tid = t.next_tid in
    t.next_tid <- t.next_tid + 1;
    Trade_id.of_int tid
  in
  let r = submit ~oid:order_id ~next_tid in
  List.iter r.fills ~f:(record_fill t book);
  let order ~size : Open_order.t =
    { symbol
    ; side
    ; px = limit_px
    ; size
    ; orig_size = Some (Size.( + ) r.filled r.remaining)
    ; order_id
    ; client_order_id
    ; timestamp = t.time
    }
  in
  let filled () : Order_status.t =
    Filled
      { order_id
      ; total = r.filled
      ; avg_px = avg_px r.fills ~filled:r.filled
      ; client_order_id
      }
  in
  let cancelled reason ~(no_fill : Reject_reason.t) : Order_status.t =
    if Size.is_zero r.filled
    then emit_reject t account ~symbol ~order_id ?client_order_id no_fill
    else (
      emit
        t
        (Order_cancelled
           { account; order = order ~size:r.remaining; reason; time = t.time });
      filled ())
  in
  match r.status with
  | Resting ->
    Option.iter (Order_book.find book order_id) ~f:(index_resting t ~symbol);
    emit t (Order_accepted { account; order = order ~size:r.remaining; time = t.time });
    Resting { order_id; client_order_id }
  | Filled ->
    emit t (Order_filled { account; order = order ~size:Size.zero; time = t.time });
    filled ()
  | Cancelled Ioc_unfilled -> cancelled Ioc_unfilled ~no_fill:No_liquidity
  | Cancelled Self_trade -> cancelled Self_trade ~no_fill:Self_trade
  | Would_cross ->
    emit_reject
      t
      account
      ~symbol
      ~order_id
      ?client_order_id
      (Post_only_would_cross
         { best_bid = Order_book.best_bid book; best_ask = Order_book.best_ask book })
;;

(* Shared checks for limit and market orders. Returns the size to submit. *)
let pre_trade_checks t account (instrument : Instrument.t) ~side ~px ~sz ~reduce_only ~cid
  : (Size.t, Reject_reason.t) Result.t
  =
  let open Result.Let_syntax in
  let symbol = instrument.symbol in
  let%bind () =
    if Instrument.valid_size instrument sz
    then Ok ()
    else Error Reject_reason.Invalid_size
  in
  let%bind () =
    match cid with
    | Some cid when Hashtbl.mem (client_id_index t account) cid ->
      Error Reject_reason.Duplicate_client_order_id
    | _ -> Ok ()
  in
  let%bind sz =
    if not reduce_only
    then Ok sz
    else (
      let reducible =
        Clearinghouse.reduce_only_size t.clearinghouse account ~symbol ~side
      in
      if Size.is_zero reducible
      then Error Reject_reason.Reduce_only_would_increase
      else Ok (Size.min sz reducible))
  in
  let%bind () =
    if reduce_only || Usd.( >= ) (Notional.mul px sz) t.config.min_order_value
    then Ok ()
    else Error (Reject_reason.Below_min_value { min = t.config.min_order_value })
  in
  let%map () =
    Clearinghouse.check_order_margin
      t.clearinghouse
      account
      ~symbol
      ~side
      ~px
      ~sz
      ~reserved:(reserved_margin t account)
      ~mark:(mark_fn t)
    |> Result.map_error ~f:(fun _ -> Reject_reason.Insufficient_margin)
  in
  sz
;;

let place_limit
  t
  account
  (instrument : Instrument.t)
  (req : Order_request.t)
  ~order_id
  ~px
  ~tif
  =
  let symbol = instrument.symbol in
  let cid = req.client_order_id in
  if not (Instrument.valid_price instrument px)
  then emit_reject t account ~symbol ~order_id ?client_order_id:cid Invalid_price
  else (
    match
      pre_trade_checks
        t
        account
        instrument
        ~side:req.side
        ~px
        ~sz:req.size
        ~reduce_only:req.reduce_only
        ~cid
    with
    | Error reason -> emit_reject t account ~symbol ~order_id ?client_order_id:cid reason
    | Ok sz ->
      submit
        t
        account
        ~symbol
        ~side:req.side
        ~limit_px:px
        ~order_id
        ~client_order_id:cid
        ~submit:(fun ~oid ~next_tid ->
          Order_book.add_limit
            (Option.value_exn (book t symbol))
            ~oid
            ~owner:account
            ~side:req.side
            ~px
            ~sz
            ~tif
            ~reduce_only:req.reduce_only
            ?cloid:cid
            ~time:t.time
            ~next_tid
            ()))
;;

let place_market
  t
  account
  (instrument : Instrument.t)
  (req : Order_request.t)
  ~order_id
  ~slippage_bps
  =
  let symbol = instrument.symbol in
  let cid = req.client_order_id in
  let slippage_bps = Option.value slippage_bps ~default:t.config.market_slippage_bps in
  let b = Option.value_exn (book t symbol) in
  match Order_book.market_limit_px b ~side:req.side ~slippage_bps with
  | None -> emit_reject t account ~symbol ~order_id ?client_order_id:cid No_liquidity
  | Some limit_px ->
    (match
       pre_trade_checks
         t
         account
         instrument
         ~side:req.side
         ~px:limit_px
         ~sz:req.size
         ~reduce_only:req.reduce_only
         ~cid
     with
     | Error reason -> emit_reject t account ~symbol ~order_id ?client_order_id:cid reason
     | Ok sz ->
       submit
         t
         account
         ~symbol
         ~side:req.side
         ~limit_px
         ~order_id
         ~client_order_id:cid
         ~submit:(fun ~oid ~next_tid ->
           Order_book.market
             b
             ~oid
             ~owner:account
             ~side:req.side
             ~sz
             ~slippage_bps
             ~reduce_only:req.reduce_only
             ?cloid:cid
             ~time:t.time
             ~next_tid
             ()))
;;

let place_internal t account (req : Order_request.t) =
  let order_id = next_order_id t in
  let status : Order_status.t =
    match instrument t req.symbol with
    | None ->
      emit_reject
        t
        account
        ~symbol:req.symbol
        ~order_id
        ?client_order_id:req.client_order_id
        Unknown_symbol
    | Some instrument ->
      (match req.order_type, req.px with
       | Limit tif, Some px -> place_limit t account instrument req ~order_id ~px ~tif
       | Limit _, None ->
         emit_reject
           t
           account
           ~symbol:req.symbol
           ~order_id
           ?client_order_id:req.client_order_id
           Invalid_price
       | Market { slippage_bps }, _ ->
         place_market t account instrument req ~order_id ~slippage_bps)
  in
  order_id, status
;;

let place_with_order_id t account request =
  let result = place_internal t account request in
  record t (Place { account; request });
  result
;;

let place t account req = snd (place_with_order_id t account req)

let reject ?symbol ?order_id ?client_order_id t account reason =
  let status = emit_reject ?symbol ?order_id ?client_order_id t account reason in
  record t (Reject { account; symbol; order_id; client_order_id; reason });
  status
;;

let owned_symbol t account oid =
  Option.bind (Hashtbl.find t.owner_orders account) ~f:(fun tbl -> Hashtbl.find tbl oid)
;;

let cancel_oid t account ~symbol ~oid ~reason : Cancel_status.t =
  match owned_symbol t account oid with
  | Some owned when Symbol.equal owned symbol ->
    if remove_resting t ~symbol oid ~reason then Cancelled else Not_found
  | _ -> Not_found
;;

let cancel t account ~symbol order_id =
  let status = cancel_oid t account ~symbol ~oid:order_id ~reason:User in
  record t (Cancel { account; symbol; order_id });
  status
;;

let oid_of_client_order_id t account cid =
  Option.bind (Hashtbl.find t.client_ids account) ~f:(fun tbl -> Hashtbl.find tbl cid)
;;

let cancel_by_client_order_id t account ~symbol client_order_id : Cancel_status.t =
  let status : Cancel_status.t =
    match oid_of_client_order_id t account client_order_id with
    | None -> Not_found
    | Some oid -> cancel_oid t account ~symbol ~oid ~reason:User
  in
  record t (Cancel_by_client_order_id { account; symbol; client_order_id });
  status
;;

let modify_internal t account (target : Target.t) (req : Order_request.t)
  : Order_status.t
  =
  let oid =
    match target with
    | Order_id oid -> Some oid
    | Client_order_id cid -> oid_of_client_order_id t account cid
  in
  let cancelled =
    match oid with
    | None -> false
    | Some oid ->
      (match owned_symbol t account oid with
       | None -> false
       | Some symbol -> remove_resting t ~symbol oid ~reason:Modified)
  in
  if cancelled
  then snd (place_internal t account req)
  else emit_reject t account ?client_order_id:req.client_order_id Order_not_found
;;

let modify t account target request =
  let status = modify_internal t account target request in
  record t (Modify { account; target; request });
  status
;;

(* Views *)

let l2 ?n_levels t symbol =
  let n_levels = Option.value n_levels ~default:t.config.l2_levels in
  book t symbol
  |> Option.map ~f:(fun b ->
    let bids, asks = Order_book.l2 b ~n_levels in
    { L2.symbol; time = t.time; bids; asks })
;;

let mids t =
  List.filter_map t.config.instruments ~f:(fun i ->
    Option.bind (book t i.symbol) ~f:Order_book.mid
    |> Option.map ~f:(fun px -> i.symbol, px))
;;

let open_orders t account =
  resting_orders_of t account
  |> List.map ~f:(fun (symbol, o) -> open_order_of_resting ~symbol o)
  |> List.sort ~compare:(fun (a : Open_order.t) b ->
    Order_id.compare b.order_id a.order_id)
;;

let fills t account = Hashtbl.find_multi t.fills account

let account_view t account =
  Clearinghouse.view t.clearinghouse account ~mark:(mark_fn t) ~time:t.time
;;

(* Marks, liquidation and funding *)

let liquidate t =
  let liquidations = Clearinghouse.mark_to_market t.clearinghouse ~mark:(mark_fn t) in
  List.iter liquidations ~f:(fun liquidation ->
    emit t (Liquidation { liquidation; time = t.time }));
  List.map liquidations ~f:(fun l -> l.account)
  |> List.dedup_and_sort ~compare:Account.compare
  |> List.iter ~f:(fun account ->
    List.iter (resting_orders_of t account) ~f:(fun (symbol, o) ->
      ignore (remove_resting t ~symbol o.oid ~reason:Liquidated : bool)))
;;

let set_mark t symbol px =
  Hashtbl.set t.marks ~key:symbol ~data:px;
  liquidate t;
  record t (Set_mark { symbol; px })
;;

let set_funding_rate t symbol rate =
  Hashtbl.set t.funding_rates ~key:symbol ~data:rate;
  record t (Set_funding_rate { symbol; rate })
;;

let funding_rate t symbol =
  Hashtbl.find t.funding_rates symbol
  |> Option.value ~default:t.config.default_funding_rate
;;

let apply_funding t =
  List.iter t.config.instruments ~f:(fun i ->
    let symbol = i.symbol in
    Option.iter (mark t symbol) ~f:(fun mark ->
      let rate = funding_rate t symbol in
      let payments = Clearinghouse.apply_funding t.clearinghouse ~symbol ~rate ~mark in
      if not (List.is_empty payments)
      then emit t (Funding { symbol; rate; mark; payments; time = t.time })))
;;

let step t ~now =
  if now < t.time
  then
    raise_s
      [%message "Exchange.step: time went backwards" (now : int) ~time:(t.time : int)];
  while t.next_funding <= now do
    t.time <- t.next_funding;
    apply_funding t;
    t.next_funding <- t.next_funding + t.config.funding_interval_ns
  done;
  t.time <- now;
  liquidate t;
  record t (Step { now })
;;

let apply t (input : Input.t) =
  match input with
  | Deposit { account; usd } -> deposit t account usd
  | Set_leverage { account; symbol; leverage } ->
    ignore (set_leverage t account symbol leverage : unit Or_error.t)
  | Place { account; request } -> ignore (place t account request : Order_status.t)
  | Reject { account; symbol; order_id; client_order_id; reason } ->
    ignore
      (reject ?symbol ?order_id ?client_order_id t account reason : Order_status.t)
  | Cancel { account; symbol; order_id } ->
    ignore (cancel t account ~symbol order_id : Cancel_status.t)
  | Cancel_by_client_order_id { account; symbol; client_order_id } ->
    ignore (cancel_by_client_order_id t account ~symbol client_order_id : Cancel_status.t)
  | Modify { account; target; request } ->
    ignore (modify t account target request : Order_status.t)
  | Set_mark { symbol; px } -> set_mark t symbol px
  | Set_funding_rate { symbol; rate } -> set_funding_rate t symbol rate
  | Step { now } -> step t ~now
;;
