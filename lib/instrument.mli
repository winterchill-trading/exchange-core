(** A tradable perpetual contract and its trading rules. A venue's universe is a list of
    instruments; its position in the list is the venue's business (e.g. an asset index). *)

open! Core

type t =
  { symbol : Symbol.t
  ; size_decimals : int (** sizes must be multiples of [10^-size_decimals] *)
  ; price_tick : Price.t (** prices must be multiples of this *)
  ; max_significant_figures : int option
  (** if set, non-integer prices have at most this many significant figures *)
  ; max_leverage : int
  ; fees : Fee_schedule.t
  }
[@@deriving sexp, compare, equal]

(** Defaults: no significant figure limit, {!Fee_schedule.default}. *)
val create
  :  ?max_significant_figures:int
  -> ?fees:Fee_schedule.t
  -> Symbol.t
  -> size_decimals:int
  -> price_tick:Price.t
  -> max_leverage:int
  -> t

(** [10^-size_decimals]. *)
val lot_size : t -> Size.t

(** Positive and a multiple of the lot size. *)
val valid_size : t -> Size.t -> bool

(** Positive, a multiple of the tick, and within the significant figure limit (integers
    are always within it). *)
val valid_price : t -> Price.t -> bool

(** The valid price nearest to a positive float (half away from zero): rounded to the
    tick, and, with a significant figure limit, to that many figures but never to more
    than whole units. *)
val round_price : t -> float -> Price.t

val find : t list -> Symbol.t -> t option
