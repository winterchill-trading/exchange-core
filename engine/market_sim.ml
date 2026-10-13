open! Core
open! Exchange_core

module Config = struct
  type t =
    { seed : int
    ; symbols : Symbol.t list
    ; initial_prices : (Symbol.t * Price.t) list
    ; vol_bps : float
    ; noise_traders : int
    ; trader_balance : Usd.t
    ; tick_interval : Time_ns.Span.t
    ; max_orders_per_symbol : int
    ; post_probability : float
    ; cancel_probability : float
    ; market_probability : float
    ; inside_touch_probability : float
    ; max_offset_bps : float
    ; min_notional : float
    ; max_notional : float
    }
  [@@deriving sexp_of]

  let default_price symbol =
    let name = String.uppercase (Symbol.to_string symbol) in
    List.find_map
      [ "BTC", 100_000; "ETH", 3_500; "SOL", 150 ]
      ~f:(fun (prefix, px) -> Option.some_if (String.is_prefix name ~prefix) px)
    |> Option.value ~default:100
    |> Price.of_int
  ;;

  let default_prices symbols = List.map symbols ~f:(fun s -> s, default_price s)

  let default =
    { seed = 0
    ; symbols = []
    ; initial_prices =
        default_prices
          (List.map Exchange.Config.default_instruments ~f:(fun i -> i.symbol))
    ; vol_bps = 5.
    ; noise_traders = 10
    ; trader_balance = Usd.of_int 10_000_000
    ; tick_interval = Time_ns.Span.of_int_ms 100
    ; max_orders_per_symbol = 5
    ; post_probability = 0.3
    ; cancel_probability = 0.1
    ; market_probability = 0.02
    ; inside_touch_probability = 0.
    ; max_offset_bps = 25.
    ; min_notional = 20.
    ; max_notional = 2000.
    }
  ;;

  let randomize ~seed =
    let random = Random.State.make [| seed; 0x5eed |] in
    let between lo hi = lo +. Random.State.float random (hi -. lo) in
    let vol_bps = between 1. 20. in
    let noise_traders = 3 + Random.State.int random 13 in
    let post_probability = between 0.1 0.5 in
    let cancel_probability = between 0.05 0.3 in
    let market_probability = between 0.005 0.05 in
    let inside_touch_probability = between 0. 0.2 in
    let max_offset_bps = between 5. 50. in
    { default with
      seed
    ; vol_bps
    ; noise_traders
    ; post_probability
    ; cancel_probability
    ; market_probability
    ; inside_touch_probability
    ; max_offset_bps
    }
  ;;
end

module Market = struct
  type t =
    { instrument : Instrument.t
    ; mutable reference : float
    ; mutable anchor : float option
    ; mutable pull : float
    (** fraction of [anchor - reference] added each tick; [0.] pins the reference to the
        anchor instead of walking *)
    ; mutable noise_traders : int (** traders [0 .. noise_traders - 1] trade it *)
    }

  let symbol t = t.instrument.symbol
end

type t =
  { config : Config.t
  ; exchange : Exchange.t
  ; random : Random.State.t
  ; markets : Market.t list
  ; mutable traders : Account.t list (** in index order *)
  ; sigma : float (** per-tick standard deviation of log returns *)
  }

let config t = t.config
let traders t = t.traders
let trader_account i = Account.of_string (sprintf "0x%s%08x" (String.make 32 'f') i)

let create (config : Config.t) exchange =
  let symbols =
    match config.symbols with
    | [] -> List.map (Exchange.instruments exchange) ~f:(fun i -> i.symbol)
    | symbols -> symbols
  in
  let markets =
    List.map symbols ~f:(fun symbol ->
      match Exchange.instrument exchange symbol with
      | Some instrument ->
        let reference =
          List.Assoc.find config.initial_prices symbol ~equal:Symbol.equal
          |> Option.value_or_thunk ~default:(fun () -> Config.default_price symbol)
          |> Price.to_float
        in
        { Market.instrument
        ; reference
        ; anchor = None
        ; pull = 0.
        ; noise_traders = config.noise_traders
        }
      | None -> raise_s [%message "Market_sim: unknown symbol" (symbol : Symbol.t)])
  in
  let traders = List.init config.noise_traders ~f:trader_account in
  List.iter traders ~f:(fun a -> Exchange.deposit exchange a config.trader_balance);
  let sigma =
    config.vol_bps /. 10_000. *. Float.sqrt (Time_ns.Span.to_sec config.tick_interval)
  in
  { config
  ; exchange
  ; random = Random.State.make [| config.seed |]
  ; markets
  ; traders
  ; sigma
  }
;;

let find_market t symbol =
  List.find t.markets ~f:(fun m -> Symbol.equal (Market.symbol m) symbol)
;;

let market_exn t symbol =
  match find_market t symbol with
  | Some m -> m
  | None -> raise_s [%message "Market_sim: symbol not simulated" (symbol : Symbol.t)]
;;

let reference_price t symbol =
  find_market t symbol
  |> Option.map ~f:(fun (m : Market.t) -> Instrument.round_price m.instrument m.reference)
;;

let set_mark t (m : Market.t) =
  Exchange.set_mark
    t.exchange
    (Market.symbol m)
    (Instrument.round_price m.instrument m.reference)
;;

let set_reference ?half_life t symbol px =
  let m = market_exn t symbol in
  let anchor = Price.to_float px in
  if Float.(anchor <= 0.)
  then
    raise_s [%message "Market_sim.set_reference: price must be positive" (px : Price.t)];
  m.anchor <- Some anchor;
  match half_life with
  | None ->
    m.pull <- 0.;
    m.reference <- anchor;
    set_mark t m
  | Some half_life ->
    if Time_ns.Span.(half_life <= zero)
    then
      raise_s
        [%message
          "Market_sim.set_reference: half_life must be positive"
            (half_life : Time_ns.Span.t)];
    let ticks = Time_ns.Span.(half_life // t.config.tick_interval) in
    m.pull <- 1. -. (0.5 ** (1. /. ticks))
;;

let noise_traders t symbol = (market_exn t symbol).noise_traders

let set_noise_traders t symbol n =
  let m = market_exn t symbol in
  if n < 0
  then raise_s [%message "Market_sim.set_noise_traders: negative count" (n : int)];
  let have = List.length t.traders in
  if n > have
  then (
    let added = List.init (n - have) ~f:(fun i -> trader_account (have + i)) in
    List.iter added ~f:(fun a -> Exchange.deposit t.exchange a t.config.trader_balance);
    t.traders <- t.traders @ added);
  (* Traders leaving the symbol take their resting orders with them. *)
  List.iteri t.traders ~f:(fun i trader ->
    if i >= n && i < m.noise_traders
    then
      Exchange.open_orders t.exchange trader
      |> List.filter ~f:(fun (o : Open_order.t) -> Symbol.equal o.symbol symbol)
      |> List.rev
      |> List.iter ~f:(fun (o : Open_order.t) ->
        ignore (Exchange.cancel t.exchange trader ~symbol o.order_id : Cancel_status.t)));
  m.noise_traders <- n
;;

let clear_reference t symbol =
  let m = market_exn t symbol in
  m.anchor <- None;
  m.pull <- 0.
;;

let uniform t lo hi = lo +. Random.State.float t.random (hi -. lo)
let chance t p = Float.(Random.State.float t.random 1. < p)
let random_side t = if Random.State.bool t.random then Side.Buy else Side.Sell

(* Box-Muller. *)
let gaussian t =
  let u1 = Float.max Float.min_positive_normal_value (Random.State.float t.random 1.) in
  let u2 = Random.State.float t.random 1. in
  Float.sqrt (-2. *. Float.log u1) *. Float.cos (2. *. Float.pi *. u2)
;;

(* A size worth a random notional at [px], rounded down to the lot size but at least one
   lot. The notional range is scaled up so that its lower end buys at least one lot,
   otherwise coarse lots (e.g. 0.001 BTC) would round most orders to zero. *)
let random_size t (m : Market.t) ~px =
  let lot = Instrument.lot_size m.instrument in
  let scale =
    if Float.(t.config.min_notional > 0.)
    then Float.max 1. (Size.to_float lot *. px /. t.config.min_notional)
    else 1.
  in
  let notional =
    uniform t (t.config.min_notional *. scale) (t.config.max_notional *. scale)
  in
  Size.max
    lot
    (Size.round_down
       ((Size.of_float [@alert "-lossy"]) (notional /. px))
       ~decimals:m.instrument.size_decimals)
;;

let cancel_oldest t trader (m : Market.t) =
  let symbol = Market.symbol m in
  let orders =
    Exchange.open_orders t.exchange trader
    |> List.filter ~f:(fun (o : Open_order.t) -> Symbol.equal o.symbol symbol)
  in
  let n = List.length orders in
  if n > t.config.max_orders_per_symbol || (n > 0 && chance t t.config.cancel_probability)
  then (
    (* [open_orders] is newest first. *)
    let oldest = List.last_exn orders in
    ignore (Exchange.cancel t.exchange trader ~symbol oldest.order_id : Cancel_status.t))
;;

let post t trader (m : Market.t) =
  if chance t t.config.post_probability
  then (
    let side = random_side t in
    let offset = uniform t 0.5 t.config.max_offset_bps /. 10_000. in
    let px =
      match side with
      | Buy -> m.reference *. (1. -. offset)
      | Sell -> m.reference *. (1. +. offset)
    in
    let limit_px = Instrument.round_price m.instrument px in
    let size = random_size t m ~px in
    if Size.is_positive size
    then
      ignore
        (Exchange.place
           t.exchange
           trader
           (Order_request.limit (Market.symbol m) side ~px:limit_px ~size)
         : Order_status.t))
;;

let market t trader (m : Market.t) =
  if chance t t.config.market_probability
  then (
    let side = random_side t in
    let size = random_size t m ~px:m.reference in
    if Size.is_positive size
    then
      ignore
        (Exchange.place
           t.exchange
           trader
           (Order_request.market (Market.symbol m) side ~size)
         : Order_status.t))
;;

(* A GTC order strictly between the best bid and ask, when the spread is wider than one
   tick, so the touch keeps tightening as well as being refilled from outside. *)
let inside_touch t trader (m : Market.t) =
  if Float.(t.config.inside_touch_probability > 0.)
     && chance t t.config.inside_touch_probability
  then (
    let symbol = Market.symbol m in
    let touch =
      Option.bind (Exchange.book t.exchange symbol) ~f:(fun b ->
        Option.both (Order_book.best_bid b) (Order_book.best_ask b))
    in
    match touch with
    | None -> ()
    | Some (bid, ask) ->
      let side = random_side t in
      let px =
        Instrument.round_price
          m.instrument
          (uniform t (Price.to_float bid) (Price.to_float ask))
      in
      if Price.( > ) px bid && Price.( < ) px ask
      then (
        let size = random_size t m ~px:(Price.to_float px) in
        ignore
          (Exchange.place t.exchange trader (Order_request.limit symbol side ~px ~size)
           : Order_status.t)))
;;

let tick t =
  List.iter t.markets ~f:(fun m ->
    (* Drawn even for pinned markets, so anchoring one symbol leaves the others' random
       streams unchanged. *)
    let step = Float.exp (t.sigma *. gaussian t) in
    (match m.anchor with
     | None -> m.reference <- m.reference *. step
     | Some anchor ->
       if Float.(m.pull = 0.)
       then m.reference <- anchor
       else m.reference <- (m.reference *. step) +. (m.pull *. (anchor -. m.reference)));
    set_mark t m);
  List.iteri t.traders ~f:(fun i trader ->
    List.iter t.markets ~f:(fun (m : Market.t) ->
      if i < m.noise_traders
      then (
        cancel_oldest t trader m;
        post t trader m;
        inside_touch t trader m;
        market t trader m)))
;;
