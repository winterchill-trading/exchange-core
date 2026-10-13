open! Core

type t =
  { lower_bound : Usd.t
  ; max_leverage : int
  }
[@@deriving sexp, compare, equal]

let find tiers ~notional =
  match tiers with
  | [] -> raise_s [%message "Margin_tier.find: no tiers"]
  | first :: rest ->
    List.fold rest ~init:first ~f:(fun acc tier ->
      if Usd.( > ) notional tier.lower_bound then tier else acc)
;;

(* [x / (2 * leverage)]: [x] times the maintenance rate of a tier. *)
let at_rate x ~leverage = Usd.div_int x (2 * leverage)

let maintenance tiers ~notional =
  match tiers with
  | [] -> raise_s [%message "Margin_tier.maintenance: no tiers"]
  | first :: rest ->
    (* Walk the tiers while the notional is above their lower bound, accumulating the
       deduction. *)
    let rec loop (current : t) deduction = function
      | (next : t) :: rest when Usd.( > ) notional next.lower_bound ->
        let deduction =
          Usd.( + )
            deduction
            (Usd.( - )
               (at_rate next.lower_bound ~leverage:next.max_leverage)
               (at_rate next.lower_bound ~leverage:current.max_leverage))
        in
        loop next deduction rest
      | _ -> Usd.( - ) (at_rate notional ~leverage:current.max_leverage) deduction
    in
    loop first Usd.zero rest
;;

let validate tiers =
  match tiers with
  | [] -> raise_s [%message "Margin_tier: no tiers"]
  | first :: _ ->
    if not (Usd.is_zero first.lower_bound)
    then raise_s [%message "Margin_tier: the first tier must start at zero" (first : t)];
    List.iter tiers ~f:(fun t ->
      if t.max_leverage < 1
      then raise_s [%message "Margin_tier: leverage must be positive" (t : t)]);
    List.iter2_exn (List.drop_last_exn tiers) (List.tl_exn tiers) ~f:(fun a b ->
      if Usd.( >= ) a.lower_bound b.lower_bound || a.max_leverage <= b.max_leverage
      then
        raise_s
          [%message
            "Margin_tier: bounds must increase and leverages decrease" (a : t) (b : t)])
;;
