open! Core
open! Exchange_core

type t =
  | Deposit of
      { account : Account.t
      ; usd : Usd.t
      }
  | Set_leverage of
      { account : Account.t
      ; symbol : Symbol.t
      ; leverage : int
      }
  | Place of
      { account : Account.t
      ; request : Order_request.t
      }
  | Reject of
      { account : Account.t
      ; symbol : Symbol.t option
      ; order_id : Order_id.t option
      ; client_order_id : Client_order_id.t option
      ; reason : Reject_reason.t
      }
  | Cancel of
      { account : Account.t
      ; symbol : Symbol.t
      ; order_id : Order_id.t
      }
  | Cancel_by_client_order_id of
      { account : Account.t
      ; symbol : Symbol.t
      ; client_order_id : Client_order_id.t
      }
  | Modify of
      { account : Account.t
      ; target : Target.t
      ; request : Order_request.t
      }
  | Set_mark of
      { symbol : Symbol.t
      ; px : Price.t
      }
  | Set_funding_rate of
      { symbol : Symbol.t
      ; rate : float
      }
  | Step of { now : int }
  | Place_trigger of
      { account : Account.t
      ; request : Order_request.t
      ; trigger : Trigger.t
      }
  | Modify_trigger of
      { account : Account.t
      ; target : Target.t
      ; request : Order_request.t
      ; trigger : Trigger.t
      }
  | Set_oracle of
      { symbol : Symbol.t
      ; px : Price.t
      }
  | Set_collar of
      { symbol : Symbol.t
      ; collar : Price_collar.Config.t option
      }
  | Set_halt_rule of { rule : Halt_rule.Config.t option }
  | Set_session_reference of
      { symbol : Symbol.t
      ; px : Price.t
      }
  | Reopen of { symbol : Symbol.t option }
[@@deriving sexp_of, compare, equal]

(* The on-disk shape. Primitive types only, so the encoding is stable whatever the
   representation of the core types; constructor order must never change. *)
module Wire = struct
  type side =
    | Buy
    | Sell
  [@@deriving bin_io]

  type tif =
    | Gtc
    | Ioc
    | Alo
  [@@deriving bin_io]

  type order_type =
    | Limit of tif
    | Market of int option
  [@@deriving bin_io]

  type request =
    { symbol : string
    ; side : side
    ; size : int
    ; px : int option
    ; order_type : order_type
    ; reduce_only : bool
    ; client_order_id : string option
    }
  [@@deriving bin_io]

  type reason =
    | Unknown_symbol
    | Unsupported of string
    | Invalid_size
    | Invalid_price
    | Duplicate_client_order_id
    | Reduce_only_would_increase
    | Below_min_value of int
    | Insufficient_margin
    | No_liquidity
    | Self_trade
    | Post_only_would_cross of int option * int option
    | Order_not_found
  [@@deriving bin_io]

  type target =
    | Order_id of int64
    | Client_order_id of string
  [@@deriving bin_io]

  type trigger_kind =
    | Take_profit
    | Stop_loss
  [@@deriving bin_io]

  type trigger =
    { trigger_px : int
    ; kind : trigger_kind
    }
  [@@deriving bin_io]

  type reference =
    | Last_trade
    | Mid
    | Mark
  [@@deriving bin_io]

  type band =
    | Bps of int
    | Ticks of int
  [@@deriving bin_io]

  type action =
    | Reject
    | Reprice
  [@@deriving bin_io]

  type collar =
    { reference : reference
    ; band : band
    ; action : action
    }
  [@@deriving bin_io]

  type scope =
    | Market_wide
    | Per_symbol
  [@@deriving bin_io]

  type reopen =
    | Automatic
    | On_request
  [@@deriving bin_io]

  type halt_rule =
    { levels : (int * int option) list
    ; scope : scope
    ; watch : string list
    ; observe : reference
    ; reopen : reopen
    }
  [@@deriving bin_io]

  type t =
    | Deposit of string * int
    | Set_leverage of string * string * int
    | Place of string * request
    | Reject of string * string option * int64 option * string option * reason
    | Cancel of string * string * int64
    | Cancel_by_client_order_id of string * string * string
    | Modify of string * target * request
    | Set_mark of string * int
    | Set_funding_rate of string * float
    | Step of int
    | Place_trigger of string * request * trigger
    | Modify_trigger of string * target * request * trigger
    | Set_oracle of string * int
    | Set_collar of string * collar option
    | Set_halt_rule of halt_rule option
    | Set_session_reference of string * int
    | Reopen of string option
  [@@deriving bin_io]
end

let side_to_wire : Side.t -> Wire.side = function
  | Buy -> Buy
  | Sell -> Sell
;;

let side_of_wire : Wire.side -> Side.t = function
  | Buy -> Buy
  | Sell -> Sell
;;

let tif_to_wire : Tif.t -> Wire.tif = function
  | Gtc -> Gtc
  | Ioc -> Ioc
  | Alo -> Alo
;;

let tif_of_wire : Wire.tif -> Tif.t = function
  | Gtc -> Gtc
  | Ioc -> Ioc
  | Alo -> Alo
;;

let request_to_wire (r : Order_request.t) : Wire.request =
  { symbol = Symbol.to_string r.symbol
  ; side = side_to_wire r.side
  ; size = Size.to_units r.size
  ; px = Option.map r.px ~f:Price.to_units
  ; order_type =
      (match r.order_type with
       | Limit tif -> Limit (tif_to_wire tif)
       | Market { slippage_bps } -> Market slippage_bps)
  ; reduce_only = r.reduce_only
  ; client_order_id = Option.map r.client_order_id ~f:Client_order_id.to_string
  }
;;

let request_of_wire (r : Wire.request) : Order_request.t =
  { symbol = Symbol.of_string r.symbol
  ; side = side_of_wire r.side
  ; size = Size.of_units r.size
  ; px = Option.map r.px ~f:Price.of_units
  ; order_type =
      (match r.order_type with
       | Limit tif -> Limit (tif_of_wire tif)
       | Market slippage_bps -> Market { slippage_bps })
  ; reduce_only = r.reduce_only
  ; client_order_id = Option.map r.client_order_id ~f:Client_order_id.of_string
  }
;;

let reason_to_wire : Reject_reason.t -> Wire.reason = function
  | Unknown_symbol -> Unknown_symbol
  | Unsupported s -> Unsupported s
  | Invalid_size -> Invalid_size
  | Invalid_price -> Invalid_price
  | Duplicate_client_order_id -> Duplicate_client_order_id
  | Reduce_only_would_increase -> Reduce_only_would_increase
  | Below_min_value { min } -> Below_min_value (Usd.to_units min)
  | Insufficient_margin -> Insufficient_margin
  | No_liquidity -> No_liquidity
  | Self_trade -> Self_trade
  | Post_only_would_cross { best_bid; best_ask } ->
    Post_only_would_cross
      (Option.map best_bid ~f:Price.to_units, Option.map best_ask ~f:Price.to_units)
  | Order_not_found -> Order_not_found
;;

let reason_of_wire : Wire.reason -> Reject_reason.t = function
  | Unknown_symbol -> Unknown_symbol
  | Unsupported s -> Unsupported s
  | Invalid_size -> Invalid_size
  | Invalid_price -> Invalid_price
  | Duplicate_client_order_id -> Duplicate_client_order_id
  | Reduce_only_would_increase -> Reduce_only_would_increase
  | Below_min_value min -> Below_min_value { min = Usd.of_units min }
  | Insufficient_margin -> Insufficient_margin
  | No_liquidity -> No_liquidity
  | Self_trade -> Self_trade
  | Post_only_would_cross (bid, ask) ->
    Post_only_would_cross
      { best_bid = Option.map bid ~f:Price.of_units
      ; best_ask = Option.map ask ~f:Price.of_units
      }
  | Order_not_found -> Order_not_found
;;

let target_to_wire : Target.t -> Wire.target = function
  | Order_id oid -> Order_id (Order_id.to_int64 oid)
  | Client_order_id cid -> Client_order_id (Client_order_id.to_string cid)
;;

let target_of_wire : Wire.target -> Target.t = function
  | Order_id oid -> Order_id (Order_id.of_int64 oid)
  | Client_order_id cid -> Client_order_id (Client_order_id.of_string cid)
;;

let trigger_to_wire ({ trigger_px; kind } : Trigger.t) : Wire.trigger =
  { trigger_px = Price.to_units trigger_px
  ; kind =
      (match kind with
       | Take_profit -> Take_profit
       | Stop_loss -> Stop_loss)
  }
;;

let trigger_of_wire ({ trigger_px; kind } : Wire.trigger) : Trigger.t =
  { trigger_px = Price.of_units trigger_px
  ; kind =
      (match kind with
       | Take_profit -> Take_profit
       | Stop_loss -> Stop_loss)
  }
;;

let reference_to_wire : Price_collar.Reference.t -> Wire.reference = function
  | Last_trade -> Last_trade
  | Mid -> Mid
  | Mark -> Mark
;;

let reference_of_wire : Wire.reference -> Price_collar.Reference.t = function
  | Last_trade -> Last_trade
  | Mid -> Mid
  | Mark -> Mark
;;

let collar_to_wire ({ reference; band; action } : Price_collar.Config.t) : Wire.collar =
  { reference = reference_to_wire reference
  ; band =
      (match band with
       | Bps n -> Bps n
       | Ticks n -> Ticks n)
  ; action =
      (match action with
       | Reject -> Reject
       | Reprice -> Reprice)
  }
;;

let collar_of_wire ({ reference; band; action } : Wire.collar) : Price_collar.Config.t =
  { reference = reference_of_wire reference
  ; band =
      (match band with
       | Bps n -> Bps n
       | Ticks n -> Ticks n)
  ; action =
      (match action with
       | Reject -> Reject
       | Reprice -> Reprice)
  }
;;

let halt_rule_to_wire ({ levels; scope; watch; observe; reopen } : Halt_rule.Config.t)
  : Wire.halt_rule
  =
  { levels = List.map levels ~f:(fun l -> l.move_bps, l.duration_ns)
  ; scope =
      (match scope with
       | Market_wide -> Market_wide
       | Per_symbol -> Per_symbol)
  ; watch = List.map watch ~f:Symbol.to_string
  ; observe = reference_to_wire observe
  ; reopen =
      (match reopen with
       | Automatic -> Automatic
       | On_request -> On_request)
  }
;;

let halt_rule_of_wire ({ levels; scope; watch; observe; reopen } : Wire.halt_rule)
  : Halt_rule.Config.t
  =
  { levels =
      List.map levels ~f:(fun (move_bps, duration_ns) ->
        { Halt_rule.Level.move_bps; duration_ns })
  ; scope =
      (match scope with
       | Market_wide -> Market_wide
       | Per_symbol -> Per_symbol)
  ; watch = List.map watch ~f:Symbol.of_string
  ; observe = reference_of_wire observe
  ; reopen =
      (match reopen with
       | Automatic -> Automatic
       | On_request -> On_request)
  }
;;

let to_wire : t -> Wire.t =
  let a = Account.to_string in
  let s = Symbol.to_string in
  function
  | Deposit { account; usd } -> Deposit (a account, Usd.to_units usd)
  | Set_leverage { account; symbol; leverage } ->
    Set_leverage (a account, s symbol, leverage)
  | Place { account; request } -> Place (a account, request_to_wire request)
  | Reject { account; symbol; order_id; client_order_id; reason } ->
    Reject
      ( a account
      , Option.map symbol ~f:s
      , Option.map order_id ~f:Order_id.to_int64
      , Option.map client_order_id ~f:Client_order_id.to_string
      , reason_to_wire reason )
  | Cancel { account; symbol; order_id } ->
    Cancel (a account, s symbol, Order_id.to_int64 order_id)
  | Cancel_by_client_order_id { account; symbol; client_order_id } ->
    Cancel_by_client_order_id
      (a account, s symbol, Client_order_id.to_string client_order_id)
  | Modify { account; target; request } ->
    Modify (a account, target_to_wire target, request_to_wire request)
  | Set_mark { symbol; px } -> Set_mark (s symbol, Price.to_units px)
  | Set_funding_rate { symbol; rate } -> Set_funding_rate (s symbol, rate)
  | Step { now } -> Step now
  | Place_trigger { account; request; trigger } ->
    Place_trigger (a account, request_to_wire request, trigger_to_wire trigger)
  | Modify_trigger { account; target; request; trigger } ->
    Modify_trigger
      (a account, target_to_wire target, request_to_wire request, trigger_to_wire trigger)
  | Set_oracle { symbol; px } -> Set_oracle (s symbol, Price.to_units px)
  | Set_collar { symbol; collar } ->
    Set_collar (s symbol, Option.map collar ~f:collar_to_wire)
  | Set_halt_rule { rule } -> Set_halt_rule (Option.map rule ~f:halt_rule_to_wire)
  | Set_session_reference { symbol; px } ->
    Set_session_reference (s symbol, Price.to_units px)
  | Reopen { symbol } -> Reopen (Option.map symbol ~f:s)
;;

let of_wire : Wire.t -> t =
  let a = Account.of_string in
  let s = Symbol.of_string in
  function
  | Deposit (account, usd) -> Deposit { account = a account; usd = Usd.of_units usd }
  | Set_leverage (account, symbol, leverage) ->
    Set_leverage { account = a account; symbol = s symbol; leverage }
  | Place (account, request) ->
    Place { account = a account; request = request_of_wire request }
  | Reject (account, symbol, order_id, client_order_id, reason) ->
    Reject
      { account = a account
      ; symbol = Option.map symbol ~f:s
      ; order_id = Option.map order_id ~f:Order_id.of_int64
      ; client_order_id = Option.map client_order_id ~f:Client_order_id.of_string
      ; reason = reason_of_wire reason
      }
  | Cancel (account, symbol, order_id) ->
    Cancel
      { account = a account; symbol = s symbol; order_id = Order_id.of_int64 order_id }
  | Cancel_by_client_order_id (account, symbol, client_order_id) ->
    Cancel_by_client_order_id
      { account = a account
      ; symbol = s symbol
      ; client_order_id = Client_order_id.of_string client_order_id
      }
  | Modify (account, target, request) ->
    Modify
      { account = a account
      ; target = target_of_wire target
      ; request = request_of_wire request
      }
  | Set_mark (symbol, px) -> Set_mark { symbol = s symbol; px = Price.of_units px }
  | Set_funding_rate (symbol, rate) -> Set_funding_rate { symbol = s symbol; rate }
  | Step now -> Step { now }
  | Place_trigger (account, request, trigger) ->
    Place_trigger
      { account = a account
      ; request = request_of_wire request
      ; trigger = trigger_of_wire trigger
      }
  | Modify_trigger (account, target, request, trigger) ->
    Modify_trigger
      { account = a account
      ; target = target_of_wire target
      ; request = request_of_wire request
      ; trigger = trigger_of_wire trigger
      }
  | Set_oracle (symbol, px) -> Set_oracle { symbol = s symbol; px = Price.of_units px }
  | Set_collar (symbol, collar) ->
    Set_collar { symbol = s symbol; collar = Option.map collar ~f:collar_of_wire }
  | Set_halt_rule rule -> Set_halt_rule { rule = Option.map rule ~f:halt_rule_of_wire }
  | Set_session_reference (symbol, px) ->
    Set_session_reference { symbol = s symbol; px = Price.of_units px }
  | Reopen symbol -> Reopen { symbol = Option.map symbol ~f:s }
;;

include
  Binable.Of_binable_without_uuid [@alert "-legacy"]
    (Wire)
    (struct
      type nonrec t = t

      let to_binable = to_wire
      let of_binable = of_wire
    end)
