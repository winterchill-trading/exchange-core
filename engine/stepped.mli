(** A deterministic, stepped exchange for testing trading strategies offline.

    A harness owns an {!Exchange.t}, optionally a {!Market_sim.t} for background flow, and
    a fixed step length. Each {!step}:
    + ticks the market simulation (marks and noise orders),
    + advances the exchange clock by [step_ns] (funding, liquidation),
    + drains the events of the step, numbered.

    The strategy under test reacts to those events by calling {!Exchange} functions on
    {!exchange} directly; its requests take effect at once and their events are returned
    by the next step. Every request, from the simulation or the strategy, is recorded as
    an {!Input.t} (and written to a {!Journal.t} if one is given), so a run can be checked
    with {!check_replay}, saved and replayed bit for bit. Nothing reads the wall clock and
    all randomness is seeded. *)

open! Core
open! Exchange_core

module Config : sig
  type t =
    { exchange : Exchange.Config.t
    ; sim : Market_sim.Config.t option (** no background flow if [None] *)
    ; step_ns : int
    }
  [@@deriving sexp_of]

  (** Default exchange and simulation, 100ms steps (the simulation's tick interval). *)
  val default : t
end

type t

(** [journal], if given, receives every input; the harness does not close it. *)
val create : ?journal:Journal.t -> Config.t -> t

val config : t -> Config.t
val exchange : t -> Exchange.t
val sim : t -> Market_sim.t option

(** Number of steps taken. *)
val steps : t -> int

(** Advances one step and returns the events since the previous step, oldest first. *)
val step : t -> Event.Numbered.t list

(** Takes [steps] steps, calling [f] after each with that step's events. *)
val run : t -> steps:int -> f:(t -> Event.Numbered.t list -> unit) -> unit

(** Every input recorded so far, oldest first. *)
val inputs : t -> Input.t list

(** Every event returned by {!step} so far, oldest first. *)
val events : t -> Event.Numbered.t list

(** Replays {!inputs} into a fresh exchange with the same configuration and checks that it
    produces the same events as {!events}; reports the first difference. *)
val check_replay : t -> unit Or_error.t
