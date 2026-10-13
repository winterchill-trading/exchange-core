open! Core
open! Exchange_core

module Config = struct
  type t =
    { interest_rate : float
    ; premium_clamp : float
    ; max_rate_per_hour : float
    ; sample_interval : Time_ns.Span.t
    ; impact_notional : (Symbol.t * Usd.t) list
    ; default_impact_notional : Usd.t
    }
  [@@deriving sexp_of]

  let default =
    { interest_rate = 0.0001
    ; premium_clamp = 0.0005
    ; max_rate_per_hour = 0.04
    ; sample_interval = Time_ns.Span.of_int_sec 5
    ; impact_notional =
        [ Symbol.of_string "BTC", Usd.of_int 20_000
        ; Symbol.of_string "ETH", Usd.of_int 20_000
        ]
    ; default_impact_notional = Usd.of_int 6_000
    }
  ;;

  let impact_notional t symbol =
    List.Assoc.find t.impact_notional symbol ~equal:Symbol.equal
    |> Option.value ~default:t.default_impact_notional
  ;;
end

(* Average fill price of [notional] against [levels], best first. *)
let impact_px levels ~notional =
  let rec loop levels ~remaining ~cost ~size =
    match levels with
    | [] -> cost, size
    | (px, sz) :: rest ->
      let px = Price.to_float px
      and sz = Size.to_float sz in
      let level_notional = px *. sz in
      if Float.(level_notional >= remaining)
      then cost +. remaining, size +. (remaining /. px)
      else
        loop
          rest
          ~remaining:(remaining -. level_notional)
          ~cost:(cost +. level_notional)
          ~size:(size +. sz)
  in
  let cost, size = loop levels ~remaining:(Usd.to_float notional) ~cost:0. ~size:0. in
  if Float.(size > 0.) then Some (cost /. size) else None
;;

let impact_pxs ~bids ~asks ~notional = impact_px bids ~notional, impact_px asks ~notional

let premium ~oracle ~impact_bid ~impact_ask =
  let above =
    Option.value_map impact_bid ~default:0. ~f:(fun b -> Float.max (b -. oracle) 0.)
  in
  let below =
    Option.value_map impact_ask ~default:0. ~f:(fun a -> Float.max (oracle -. a) 0.)
  in
  (above -. below) /. oracle
;;

let rate (c : Config.t) ~average_premium ~interval =
  let p = average_premium in
  let eight_hour =
    p
    +. Float.clamp_exn
         (c.interest_rate -. p)
         ~min:(-.c.premium_clamp)
         ~max:c.premium_clamp
  in
  let hours = Time_ns.Span.to_hr interval in
  let cap = c.max_rate_per_hour *. hours in
  Float.clamp_exn (eight_hour *. hours /. 8.) ~min:(-.cap) ~max:cap
;;
