open! Core
open! Exchange_core

module Config = struct
  type t =
    { exchange : Exchange.Config.t
    ; sim : Market_sim.Config.t option
    ; step_ns : int
    }
  [@@deriving sexp_of]

  let default =
    { exchange = Exchange.Config.default
    ; sim = Some Market_sim.Config.default
    ; step_ns = Time_ns.Span.to_int_ns Market_sim.Config.default.tick_interval
    }
  ;;
end

type t =
  { config : Config.t
  ; exchange : Exchange.t
  ; sim : Market_sim.t option
  ; inputs : Input.t Queue.t
  ; events : Event.Numbered.t Queue.t
  ; mutable steps : int
  }

let create ?journal (config : Config.t) =
  let exchange = Exchange.create ~config:config.exchange () in
  let inputs = Queue.create () in
  Exchange.record_inputs exchange ~f:(Queue.enqueue inputs);
  Option.iter journal ~f:(fun journal -> Journal.attach journal exchange);
  (* Created after the recorders so the noise traders' deposits are recorded too. *)
  let sim = Option.map config.sim ~f:(fun sim -> Market_sim.create sim exchange) in
  { config; exchange; sim; inputs; events = Queue.create (); steps = 0 }
;;

let config t = t.config
let exchange t = t.exchange
let sim t = t.sim
let steps t = t.steps
let inputs t = Queue.to_list t.inputs
let events t = Queue.to_list t.events

let step t =
  Option.iter t.sim ~f:Market_sim.tick;
  Exchange.step t.exchange ~now:(Exchange.now t.exchange + t.config.step_ns);
  t.steps <- t.steps + 1;
  let events = Exchange.drain_numbered_events t.exchange in
  Queue.enqueue_all t.events events;
  events
;;

let run t ~steps ~f =
  for _ = 1 to steps do
    f t (step t)
  done
;;

let check_replay t =
  let replayed = Journal.replay ~config:t.config.exchange (inputs t) in
  let expected = events t in
  (* Requests made after the last step have events not drained from the original yet. *)
  let actual =
    List.take (Exchange.drain_numbered_events replayed) (List.length expected)
  in
  let rec diff (expected : Event.Numbered.t list) (actual : Event.Numbered.t list) =
    match expected, actual with
    | [], [] -> Ok ()
    | e :: _, [] ->
      Or_error.error_s [%message "Stepped: replay is missing events" ~from:(e.seq : int)]
    | [], a :: _ ->
      Or_error.error_s [%message "Stepped: replay has extra events" ~from:(a.seq : int)]
    | e :: expected, a :: actual ->
      if Sexp.equal (Event.Numbered.sexp_of_t e) (Event.Numbered.sexp_of_t a)
      then diff expected actual
      else
        Or_error.error_s
          [%message
            "Stepped: replay diverged"
              ~expected:(e : Event.Numbered.t)
              ~replayed:(a : Event.Numbered.t)]
  in
  diff expected actual
;;
