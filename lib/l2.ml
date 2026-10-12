open! Core

module Level = struct
  type t =
    { px : Price.t
    ; sz : Size.t
    ; n : int
    }
  [@@deriving sexp, compare, equal]
end

type t =
  { symbol : Symbol.t
  ; time : int
  ; bids : Level.t list
  ; asks : Level.t list
  }
[@@deriving sexp, compare, equal]

let best_bid t = List.hd t.bids
let best_ask t = List.hd t.asks
