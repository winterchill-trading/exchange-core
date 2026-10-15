(** A per-symbol price collar: aggressive orders may not trade more than a band away from
    a reference price, the guard real venues call price banding, collars or aberrant-trade
    protection.

    The band is checked on the aggressor's side. A buy may not trade above
    [upper reference], a sell not below [lower reference]. A resting order left outside
    the band by a moving reference can still fill, at a price better than the band for the
    aggressor, as on the venues that run collars. Post-only orders never trade on entry
    and are not checked. *)

open! Core
open! Exchange_core

(** Where the reference price comes from. *)
module Reference : sig
  type t =
    | Last_trade (** last trade price in the symbol *)
    | Mid (** book mid, both sides present *)
    | Mark
    (** the exchange mark: the last [set_mark] (which is what [Market_sim.set_reference]
        feeds), else the oracle mark, else last trade, else mid *)
  [@@deriving sexp, compare, equal]
end

module Band : sig
  type t =
    | Bps of int (** basis points of the reference *)
    | Ticks of int (** multiples of the instrument's tick *)
  [@@deriving sexp, compare, equal]
end

module Action : sig
  type t =
    | Reject
    (** a marketable limit order priced beyond the band is rejected; market orders are
        always re-priced (their protection price is clamped) *)
    | Reprice (** the limit is moved to the band and the order proceeds *)
  [@@deriving sexp, compare, equal]
end

module Config : sig
  type t =
    { reference : Reference.t
    ; band : Band.t
    ; action : Action.t
    }
  [@@deriving sexp, compare, equal]

  (** An error if the band is not positive. *)
  val validate : t -> unit Or_error.t
end

(** The step between valid prices of the instrument around a price: its tick, or with a
    significant figure limit the coarser step the limit imposes at that magnitude. *)
val step : Instrument.t -> Price.t -> Price.t

(** The highest price a buy may trade at: [reference] plus the band, rounded down to a
    valid price of the instrument (tick and significant figures), but never below the
    first valid price at or above [reference] (a band narrower than the price grid). *)
val upper : Config.t -> Instrument.t -> reference:Price.t -> Price.t

(** The lowest price a sell may trade at: [reference] minus the band, rounded up to a
    valid price, never above the last valid price at or below [reference], and at least
    one tick. *)
val lower : Config.t -> Instrument.t -> reference:Price.t -> Price.t

(** [upper] for a buy, [lower] for a sell. *)
val bound : Config.t -> Instrument.t -> reference:Price.t -> side:Side.t -> Price.t

(** Whether a limit price lies beyond the bound on the order's side. *)
val beyond : side:Side.t -> limit:Price.t -> bound:Price.t -> bool
