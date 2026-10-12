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

let to_wire : t -> Wire.t =
  let a = Account.to_string in
  let s = Symbol.to_string in
  function
  | Deposit { account; usd } -> Deposit (a account, Usd.to_units usd)
  | Set_leverage { account; symbol; leverage } -> Set_leverage (a account, s symbol, leverage)
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
;;

include
  Binable.Of_binable_without_uuid [@alert "-legacy"]
    (Wire)
    (struct
      type nonrec t = t

      let to_binable = to_wire
      let of_binable = of_wire
    end)
