open! Core
open! Exchange_core

module Reference = struct
  type t =
    | Last_trade
    | Mid
    | Mark
  [@@deriving sexp, compare, equal]
end

module Band = struct
  type t =
    | Bps of int
    | Ticks of int
  [@@deriving sexp, compare, equal]
end

module Action = struct
  type t =
    | Reject
    | Reprice
  [@@deriving sexp, compare, equal]
end

module Config = struct
  type t =
    { reference : Reference.t
    ; band : Band.t
    ; action : Action.t
    }
  [@@deriving sexp, compare, equal]

  let validate t =
    match t.band with
    | Bps n | Ticks n ->
      if n > 0
      then Ok ()
      else Or_error.error_s [%message "Price_collar: band must be positive" (t : t)]
  ;;
end

(* [units * bps / 10_000] without overflowing for any price an [int] holds. *)
let bps_of units bps = (units / 10_000 * bps) + (units % 10_000 * bps / 10_000)
let rec digits n = if n < 10 then 1 else 1 + digits (n / 10)
let rec pow10 n = if n <= 0 then 1 else 10 * pow10 (n - 1)

(* The step between valid prices around [units]: the tick, and with a significant figure
   limit also [10^(digits - n)] units, capped at one whole unit (integers always pass). *)
let granularity (i : Instrument.t) units =
  let tick = Price.to_units i.price_tick in
  match i.max_significant_figures with
  | None -> tick
  | Some n ->
    let g = Int.min Price.units_per_one (pow10 (digits (Int.max 1 units) - n)) in
    let rec gcd a b = if b = 0 then a else gcd b (a % b) in
    tick / gcd tick g * g
;;

let floor_valid i units =
  let g = granularity i units in
  units - (units % g)
;;

let ceil_valid i units =
  let g = granularity i units in
  let r = units % g in
  if r = 0 then units else units + g - r
;;

let delta (c : Config.t) (i : Instrument.t) ~reference =
  match c.band with
  | Bps n -> bps_of (Price.to_units reference) n
  | Ticks n -> n * Price.to_units i.price_tick
;;

let step i px = Price.of_units (granularity i (Price.to_units px))

(* Rounded inward, but never past the reference: a band narrower than the price grid still
   lets a buy trade at the first valid price at or above the reference. *)
let upper c i ~reference =
  let r = Price.to_units reference in
  Price.of_units (Int.max (floor_valid i (r + delta c i ~reference)) (ceil_valid i r))
;;

let lower c (i : Instrument.t) ~reference =
  let r = Price.to_units reference in
  let tick = Price.to_units i.price_tick in
  let raw = Int.max tick (r - delta c i ~reference) in
  Price.of_units (Int.max tick (Int.min (ceil_valid i raw) (floor_valid i r)))
;;

let bound c i ~reference ~(side : Side.t) =
  match side with
  | Buy -> upper c i ~reference
  | Sell -> lower c i ~reference
;;

let beyond ~(side : Side.t) ~limit ~bound =
  match side with
  | Buy -> Price.( > ) limit bound
  | Sell -> Price.( < ) limit bound
;;
