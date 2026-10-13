open! Core
open! Exchange_core

module Config = struct
  type t =
    { liquidator : Account.t
    ; partial_above : Usd.t
    ; partial_fraction : float
    ; cooldown : Time_ns.Span.t
    ; backstop_fraction : float
    }
  [@@deriving sexp_of, equal]

  let create ~liquidator =
    { liquidator
    ; partial_above = Usd.of_int 100_000
    ; partial_fraction = 0.2
    ; cooldown = Time_ns.Span.of_int_sec 30
    ; backstop_fraction = 2. /. 3.
    }
  ;;
end

module Method = struct
  type t =
    | Market
    | Backstop
  [@@deriving sexp_of, compare, equal]
end

module Event = struct
  type t =
    { account : Account.t
    ; symbol : Symbol.t
    ; method_ : Method.t
    ; order_id : Order_id.t option
    ; size : Size.t
    ; order_size : Size.t
    ; mark : Price.t
    ; equity : Usd.t
    ; notional : Usd.t
    ; time : int
    ; before_seq : int
    }
  [@@deriving sexp_of]
end
