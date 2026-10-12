open! Core

type t =
  { symbol : Symbol.t
  ; size_decimals : int
  ; price_tick : Price.t
  ; max_significant_figures : int option
  ; max_leverage : int
  ; fees : Fee_schedule.t
  }
[@@deriving sexp, compare, equal]

let pow10 n = Int.pow 10 n

let tick_of_decimals decimals =
  let decimals = Int.clamp_exn decimals ~min:0 ~max:Price.decimals in
  Price.of_units (Price.units_per_one / pow10 decimals)
;;

let create
  ?max_significant_figures
  ?(fees = Fee_schedule.default)
  symbol
  ~size_decimals
  ~price_tick
  ~max_leverage
  =
  { symbol; size_decimals; price_tick; max_significant_figures; max_leverage; fees }
;;

let lot_size t = Size.of_units (Size.units_per_one / pow10 t.size_decimals)

let valid_size t sz =
  Size.is_positive sz && Size.equal sz (Size.round_down sz ~decimals:t.size_decimals)
;;

let significant_figures px =
  Price.to_string px
  |> String.filter ~f:Char.is_digit
  |> String.lstrip ~drop:(Char.equal '0')
  |> String.length
;;

let valid_price t px =
  Price.is_positive px
  && Price.to_units px % Price.to_units t.price_tick = 0
  &&
  match t.max_significant_figures with
  | None -> true
  | Some n -> Price.to_units px % Price.units_per_one = 0 || significant_figures px <= n
;;

(* [Some k] when the tick is [10^-k]. *)
let tick_decimals t =
  List.find
    (List.range 0 (Price.decimals + 1))
    ~f:(fun k -> Price.equal t.price_tick (tick_of_decimals k))
;;

let round_to_tick t px =
  let tick = Price.to_units t.price_tick in
  let units = Price.to_units px in
  let q = units / tick
  and r = units % tick in
  Price.of_units (if 2 * r >= tick then (q + 1) * tick else q * tick)
;;

let round_price t x =
  let px = Price.of_float x in
  let sig_decimals =
    Option.map t.max_significant_figures ~f:(fun n ->
      let int_digits = Float.iround_down_exn (Float.log10 x) + 1 in
      n - int_digits)
  in
  match tick_decimals t, sig_decimals with
  | Some k, None -> Price.round_nearest px ~decimals:k
  | Some k, Some s -> Price.round_nearest px ~decimals:(Int.max 0 (Int.min k s))
  | None, None -> round_to_tick t px
  | None, Some s -> round_to_tick t (Price.round_nearest px ~decimals:(Int.max 0 s))
;;

let find ts symbol = List.find ts ~f:(fun t -> Symbol.equal t.symbol symbol)
