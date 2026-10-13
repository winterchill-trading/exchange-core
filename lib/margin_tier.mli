(** Margin tiers (Hyperliquid docs, "Margin tiers"): the maximum leverage of a position
    falls as its notional grows. Tier [n] applies to a notional above its [lower_bound];
    its maintenance margin rate is half the initial margin rate at its [max_leverage], and

    {v
    maintenance_margin = notional * maintenance_rate(n) - deduction(n)
    deduction(0) = 0
    deduction(n) = deduction(n - 1) + lower_bound(n) * (maintenance_rate(n) - maintenance_rate(n - 1))
    v}

    so the maintenance margin is continuous in the notional. A list of tiers is sorted by
    [lower_bound], the first one at zero. *)

open! Core

type t =
  { lower_bound : Usd.t
  ; max_leverage : int
  }
[@@deriving sexp, compare, equal]

(** The tier of a position with [notional] (absolute): the last whose lower bound is below
    it, else the first. Raises on an empty list. *)
val find : t list -> notional:Usd.t -> t

(** The maintenance margin of a position with [notional] (absolute). Raises on an empty
    list. *)
val maintenance : t list -> notional:Usd.t -> Usd.t

(** Raises unless the list is non-empty, starts at zero, and has increasing lower bounds
    and decreasing leverages, all positive. *)
val validate : t list -> unit
