(** Aggregated order book snapshot, best price first on each side. *)

open! Core

module Level : sig
  type t =
    { px : Price.t
    ; sz : Size.t
    ; n : int (** number of orders at this level *)
    }
  [@@deriving sexp, compare, equal]
end

type t =
  { symbol : Symbol.t
  ; time : int (** nanoseconds, from the exchange clock *)
  ; bids : Level.t list
  ; asks : Level.t list
  }
[@@deriving sexp, compare, equal]

val best_bid : t -> Level.t option
val best_ask : t -> Level.t option
