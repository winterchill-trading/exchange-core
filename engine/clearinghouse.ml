open! Core
open! Exchange_core
module Notional = Fixed_decimal.Product (Price) (Size) (Usd)

(* Dimensionless fractions such as fee and funding rates. *)
module Rate = Fixed_decimal.Make ()
module Fee = Fixed_decimal.Product (Usd) (Rate) (Usd)

let rate_of_bps bps = Rate.of_float (bps /. 10_000.)

module Market = struct
  type t =
    { instrument : Instrument.t
    ; taker_rate : Rate.t
    ; maker_rate : Rate.t
    }
  [@@deriving sexp_of]

  let create (instrument : Instrument.t) =
    { instrument
    ; taker_rate = rate_of_bps instrument.fees.taker_bps
    ; maker_rate = rate_of_bps instrument.fees.maker_bps
    }
  ;;
end

type t =
  { instruments : Instrument.t list
  ; markets : Market.t Symbol.Table.t
  ; default_leverage : int
  ; accounts : Account_state.t Account.Table.t
  ; mutable sorted_accounts : Account_state.t Account.Map.t [@sexp.opaque]
  (** every account, kept sorted as accounts are created *)
  ; mutable with_positions : Account_state.t Account.Map.t [@sexp.opaque]
  (** accounts with at least one open position; marking and funding visit only these *)
  ; mutable fees_collected : Usd.t
  }
[@@deriving sexp_of]

let create ?(default_leverage = 20) instruments =
  let markets = Symbol.Table.create () in
  List.iter instruments ~f:(fun (i : Instrument.t) ->
    Hashtbl.set markets ~key:i.symbol ~data:(Market.create i));
  { instruments
  ; markets
  ; default_leverage
  ; accounts = Account.Table.create ()
  ; sorted_accounts = Account.Map.empty
  ; with_positions = Account.Map.empty
  ; fees_collected = Usd.zero
  }
;;

let instruments t = t.instruments
let fees_collected t = t.fees_collected

let market t symbol =
  match Hashtbl.find t.markets symbol with
  | Some m -> m
  | None -> raise_s [%message "Clearinghouse: unknown symbol" (symbol : Symbol.t)]
;;

let instrument t symbol = (market t symbol).instrument

let account t account =
  Hashtbl.find_and_call1
    t.accounts
    account
    ~a:t
    ~if_found:(fun state _ -> state)
    ~if_not_found:(fun account t ->
      let state = Account_state.create account in
      Hashtbl.set t.accounts ~key:account ~data:state;
      t.sorted_accounts <- Map.set t.sorted_accounts ~key:account ~data:state;
      state)
;;

let find_account t account = Hashtbl.find t.accounts account
let accounts t = Map.data t.sorted_accounts

let has_open_position (state : Account_state.t) =
  Hashtbl.exists state.positions ~f:(fun p -> not (Position.is_flat p))
;;

(* Adds [state] to [with_positions] once its position [p] is open. An account that goes
   flat stays until the next [mark_to_market] prunes it, so a position opened and closed
   between two steps does not rebuild the map twice. *)
let note_position t (state : Account_state.t) (p : Position.t) =
  if (not (Position.is_flat p)) && not (Map.mem t.with_positions state.account)
  then t.with_positions <- Map.set t.with_positions ~key:state.account ~data:state
;;

let deposit t account_id usd = Account_state.add_balance (account t account_id) usd
let max_leverage t symbol = (instrument t symbol).max_leverage

let leverage t account symbol =
  let default = Int.min t.default_leverage (max_leverage t symbol) in
  match find_account t account with
  | None -> default
  | Some a -> Option.value (Account_state.leverage a symbol) ~default
;;

let set_leverage t account_id symbol lev =
  let max = max_leverage t symbol in
  if lev < 1 || lev > max
  then
    Or_error.error_s
      [%message
        "Invalid leverage" (symbol : Symbol.t) (lev : int) ~max_leverage:(max : int)]
  else Ok (Account_state.set_leverage (account t account_id) symbol lev)
;;

type mark = Symbol.t -> Price.t option

let mark_of ~mark (p : Position.t) = Option.value (mark p.symbol) ~default:p.entry_px

let positions t account =
  match find_account t account with
  | None -> []
  | Some a -> Account_state.open_positions a
;;

let sum_positions t account ~f = Usd.sum (List.map (positions t account) ~f)

let balance t account =
  Option.value_map (find_account t account) ~default:Usd.zero ~f:(fun a -> a.balance)
;;

let equity t account ~mark =
  Usd.( + )
    (balance t account)
    (sum_positions t account ~f:(fun p ->
       Position.unrealized_pnl p ~mark:(mark_of ~mark p)))
;;

let abs_notional ~mark p = Usd.abs (Position.notional p ~mark:(mark_of ~mark p))

let position_margin t account ~mark (p : Position.t) =
  Usd.div_int (abs_notional ~mark p) (leverage t account p.symbol)
;;

let position_maintenance t ~mark (p : Position.t) =
  Usd.div_int (abs_notional ~mark p) (2 * max_leverage t p.symbol)
;;

let margin_used t account ~mark =
  sum_positions t account ~f:(position_margin t account ~mark)
;;

let maintenance_margin t account ~mark =
  sum_positions t account ~f:(position_maintenance t ~mark)
;;

let current_size t account symbol =
  match find_account t account with
  | None -> Size.zero
  | Some a ->
    Option.value_map (Account_state.position a symbol) ~default:Size.zero ~f:(fun p ->
      p.size)
;;

let reduce_only_size t account ~symbol ~side =
  let size = current_size t account symbol in
  match (side : Side.t) with
  | Sell when Size.is_positive size -> size
  | Buy when Size.is_negative size -> Size.neg size
  | Buy | Sell -> Size.zero
;;

let order_margin t account ~symbol ~side ~px ~sz =
  let reducible = reduce_only_size t account ~symbol ~side in
  let increase = Size.max Size.zero (Size.( - ) sz reducible) in
  Usd.div_int (Notional.mul px increase) (leverage t account symbol)
;;

let check_order_margin t account ~symbol ~side ~px ~sz ~reserved ~mark =
  let required = order_margin t account ~symbol ~side ~px ~sz in
  let available =
    Usd.( - ) (Usd.( - ) (equity t account ~mark) (margin_used t account ~mark)) reserved
  in
  if Usd.( <= ) required available
  then Ok ()
  else
    Or_error.error_s
      [%message
        "Insufficient margin to place order" (required : Usd.t) (available : Usd.t)]
;;

module Settlement = struct
  type t =
    { account : Account.t
    ; side : Side.t
    ; crossed : bool
    ; fee : Usd.t
    ; change : Position.Change.t
    }
  [@@deriving sexp_of, compare, equal]
end

let settle_side t (fill : Order_book.Fill.t) ~account:account_id ~side ~crossed
  : Settlement.t
  =
  let state = account t account_id in
  let position = Account_state.position_or_create state fill.symbol in
  let change = Position.apply_trade position ~side ~px:fill.px ~sz:fill.sz in
  note_position t state position;
  let m = market t fill.symbol in
  let rate = if crossed then m.taker_rate else m.maker_rate in
  let fee = Fee.mul (Notional.mul fill.px fill.sz) rate in
  Account_state.add_balance state (Usd.( - ) change.closed_pnl fee);
  t.fees_collected <- Usd.( + ) t.fees_collected fee;
  { account = account_id; side; crossed; fee; change }
;;

let settle_fill t (fill : Order_book.Fill.t) =
  let taker =
    settle_side t fill ~account:fill.taker ~side:fill.taker_side ~crossed:true
  in
  let maker =
    settle_side
      t
      fill
      ~account:fill.maker
      ~side:(Order_book.Fill.maker_side fill)
      ~crossed:false
  in
  taker, maker
;;

module Liquidation = struct
  type t =
    { account : Account.t
    ; symbol : Symbol.t
    ; size : Size.t
    ; px : Price.t
    ; pnl : Usd.t
    }
  [@@deriving sexp_of, compare, equal]
end

let liquidate_account (state : Account_state.t) ~mark =
  let account = state.account in
  List.map (Account_state.open_positions state) ~f:(fun p ->
    let px = mark_of ~mark p in
    let size = p.size in
    let pnl = Position.close_at p ~px in
    Account_state.add_balance state pnl;
    { Liquidation.account; symbol = p.symbol; size; px; pnl })
;;

let mark_to_market t ~mark =
  (* Accounts are visited from the highest id down so the result, built by prepending, is
     in account order. *)
  let liquidations, flat =
    Map.fold_right
      t.with_positions
      ~init:([], [])
      ~f:(fun ~key:account ~data:state ((liquidations, flat) as acc) ->
        if not (has_open_position state)
        then liquidations, account :: flat
        else if Usd.( >= ) (equity t account ~mark) (maintenance_margin t account ~mark)
        then acc
        else liquidate_account state ~mark @ liquidations, account :: flat)
  in
  List.iter flat ~f:(fun account ->
    t.with_positions <- Map.remove t.with_positions account);
  liquidations
;;

module Funding_payment = struct
  type t =
    { account : Account.t
    ; symbol : Symbol.t
    ; size : Size.t
    ; payment : Usd.t
    }
  [@@deriving sexp_of, compare, equal]
end

let apply_funding t ~symbol ~rate ~mark =
  let rate = Rate.of_float rate in
  (* [with_positions] may still hold accounts that went flat since the last
     [mark_to_market]; they have no position in [symbol] and are skipped. *)
  List.filter_map (Map.data t.with_positions) ~f:(fun state ->
    Account_state.position state symbol
    |> Option.map ~f:(fun p ->
      let payment = Fee.mul (Position.notional p ~mark) rate in
      Account_state.add_balance state (Usd.neg payment);
      Position.add_funding p payment;
      { Funding_payment.account = state.account; symbol; size = p.size; payment }))
;;

(* Estimated liquidation price of [p] holding everything else fixed: the mark at which
   equity meets maintenance margin. Uses floats; it is informational only. *)
let liquidation_px t ~mark ~equity ~maintenance (p : Position.t) =
  let side = if Size.is_positive p.size then 1. else -1. in
  let mark_px = Price.to_float (mark_of ~mark p) in
  let size = Float.abs (Size.to_float p.size) in
  let l = 1. /. Float.of_int (2 * max_leverage t p.symbol) in
  let margin_available = Usd.to_float equity -. Usd.to_float maintenance in
  let liq = mark_px -. (side *. margin_available /. size /. (1. -. (l *. side))) in
  if Float.( > ) liq 0. then Some (Price.of_float liq) else None
;;

let view t account ~mark ~time : Account_view.t =
  let equity = equity t account ~mark in
  let maintenance = maintenance_margin t account ~mark in
  let positions =
    List.map (positions t account) ~f:(fun p : Position_view.t ->
      { symbol = p.symbol
      ; size = p.size
      ; entry_px = p.entry_px
      ; notional = abs_notional ~mark p
      ; unrealized_pnl = Position.unrealized_pnl p ~mark:(mark_of ~mark p)
      ; realized_pnl = p.realized_pnl
      ; cum_funding = p.cum_funding
      ; liquidation_px = liquidation_px t ~mark ~equity ~maintenance p
      ; leverage = leverage t account p.symbol
      ; max_leverage = max_leverage t p.symbol
      ; margin_used = position_margin t account ~mark p
      })
  in
  let margin_used = margin_used t account ~mark in
  { account
  ; balance = balance t account
  ; equity
  ; total_notional = sum_positions t account ~f:(abs_notional ~mark)
  ; margin_used
  ; maintenance_margin = maintenance
  ; available = Usd.max Usd.zero (Usd.( - ) equity margin_used)
  ; positions
  ; time
  }
;;
