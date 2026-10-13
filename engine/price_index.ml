open! Core

module Ema = struct
  type t =
    { tau_s : float
    ; mutable numerator : float
    ; mutable denominator : float
    ; mutable last : float option
    }
  [@@deriving sexp_of]

  let create ~tau =
    { tau_s = Time_ns.Span.to_sec tau; numerator = 0.; denominator = 0.; last = None }
  ;;

  let update t ~sample ~dt =
    let dt_s = Time_ns.Span.to_sec dt in
    let decay = Float.exp (-.dt_s /. t.tau_s) in
    t.numerator <- (t.numerator *. decay) +. (sample *. dt_s);
    t.denominator <- (t.denominator *. decay) +. dt_s;
    t.last <- Some sample
  ;;

  let value t =
    if Float.(t.denominator > 0.) then Some (t.numerator /. t.denominator) else t.last
  ;;
end

type t =
  { mutable oracle : float option
  ; mutable updated_at : int option
  ; mid_minus_oracle : Ema.t (** 150 s *)
  ; book_median : Ema.t (** 30 s *)
  }
[@@deriving sexp_of]

let create () =
  { oracle = None
  ; updated_at = None
  ; mid_minus_oracle = Ema.create ~tau:(Time_ns.Span.of_int_sec 150)
  ; book_median = Ema.create ~tau:(Time_ns.Span.of_int_sec 30)
  }
;;

let oracle t = t.oracle

let median xs =
  let xs = List.sort xs ~compare:Float.compare |> Array.of_list in
  let n = Array.length xs in
  if n = 0
  then None
  else if n % 2 = 1
  then Some xs.(n / 2)
  else Some ((xs.((n / 2) - 1) +. xs.(n / 2)) /. 2.)
;;

let update t ~now ~oracle ~mid ~best_bid ~best_ask ~last_trade =
  let dt =
    match t.updated_at with
    | None -> Time_ns.Span.zero
    | Some at -> Time_ns.Span.of_int_ns (Int.max 0 (now - at))
  in
  t.oracle <- Some oracle;
  t.updated_at <- Some now;
  Option.iter mid ~f:(fun mid ->
    Ema.update t.mid_minus_oracle ~sample:(mid -. oracle) ~dt);
  let book = median (List.filter_opt [ best_bid; best_ask; last_trade ]) in
  Option.iter book ~f:(fun sample -> Ema.update t.book_median ~sample ~dt);
  let oracle_based =
    Option.map (Ema.value t.mid_minus_oracle) ~f:(fun ema -> oracle +. ema)
  in
  (* The third input, other venues' perp mids, is never available here. *)
  let inputs = List.filter_opt [ oracle_based; book ] in
  let inputs =
    if List.length inputs = 2
    then inputs @ Option.to_list (Ema.value t.book_median)
    else inputs
  in
  Option.value (median inputs) ~default:oracle
;;
